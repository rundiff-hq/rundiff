require "test_helper"

class GithubPullRequestExecutionFinalizeJobTest < ActiveJob::TestCase
  class TestJob < GithubPullRequestExecutionFinalizeJob
    attr_accessor :authentication_override, :client_override, :publisher_override

    private

    def app_authentication
      authentication_override
    end

    def pull_request_client(token:)
      raise "unexpected token" unless token == "installation-token"

      client_override
    end

    def execution_publisher(token:)
      raise "unexpected publish token" unless token == "installation-token"

      publisher_override
    end
  end

  test "publishes and completes a successful current executor result" do
    execution = running_execution
    publisher = counting_publisher

    perform_job(
      execution:,
      result: RunDiff::Executor::Result.success(payload),
      client: sequence_client([ current_pull_request ]),
      publisher:
    )

    execution.reload
    assert_equal "completed", execution.status
    assert_equal "allow", execution.outcome
    assert_equal payload, execution.result
    assert_equal 1, execution.attempt_count
    assert_equal 1, publisher.calls
    assert_equal 0, publisher.infra_calls
  end

  test "persists and publishes a serialized executor infrastructure failure" do
    execution = running_execution
    publisher = counting_publisher

    perform_job(
      execution:,
      result: RunDiff::Executor::Result.failure(RuntimeError.new("worker unavailable")),
      client: sequence_client([ current_pull_request ]),
      publisher:
    )

    execution.reload
    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
    assert_equal "RuntimeError: worker unavailable", execution.failure
    assert execution.rerunnable?
    assert_equal [ "RuntimeError" ], publisher.failure_classes
  end

  test "marks an old result stale before publication" do
    execution = running_execution
    stale = current_pull_request.deep_dup
    stale["head"]["sha"] = "newer-head"
    publisher = counting_publisher

    perform_job(
      execution:,
      result: RunDiff::Executor::Result.success(payload),
      client: sequence_client([ stale ]),
      publisher:
    )

    execution.reload
    assert_equal "ignored", execution.status
    assert_equal "stale", execution.outcome
    assert_equal "stale_head_before_finalize", execution.failure
    assert_equal 0, publisher.calls
    assert_equal 0, publisher.infra_calls
  end

  test "ignores a late executor result after its lease has expired" do
    execution = running_execution
    execution.update!(lease_expires_at: 1.minute.ago)

    job = TestJob.new
    job.perform(execution.execution_id, RunDiff::Executor::Result.success(payload).to_h)

    execution.reload
    assert_equal "running", execution.status
    assert execution.lease_expired?
  end

  test "ignores a duplicate result after the execution is terminal" do
    execution = running_execution
    execution.complete!(payload)

    job = TestJob.new
    job.perform(execution.execution_id, RunDiff::Executor::Result.success(payload).to_h)

    assert_equal "completed", execution.reload.status
    assert_equal 1, execution.attempt_count
  end

  test "ignores a late result after cancellation without publishing regression or infrastructure failure" do
    execution = running_execution
    publisher = counting_publisher
    execution.cancel!(attempt_number: execution.attempt_count, reason: "user_cancelled")

    job = TestJob.new
    job.authentication_override = fake_authentication
    job.client_override = sequence_client([])
    job.publisher_override = publisher
    job.perform(execution.execution_id, RunDiff::Executor::Result.success(payload).to_h)

    execution.reload
    assert_equal "cancelled", execution.status
    assert_equal "cancelled", execution.outcome
    assert_equal "user_cancelled", execution.cancellation_reason
    assert_equal({}, execution.result)
    assert_equal 0, publisher.calls
    assert_equal 0, publisher.infra_calls
  end

  private

  def perform_job(execution:, result:, client:, publisher:)
    job = TestJob.new
    job.authentication_override = fake_authentication
    job.client_override = client
    job.publisher_override = publisher
    job.perform(execution.execution_id, result.to_h)
  end

  def running_execution
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(32)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 36,
        "installation_id" => 123,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    )
    execution.claim!
    execution
  end

  def payload
    {
      "run_id" => "run",
      "result" => {
        "decision" => "allow",
        "merge_recommendation" => "allow"
      }
    }
  end

  def current_pull_request
    {
      "base" => { "ref" => "main", "sha" => "base-sha" },
      "head" => { "ref" => "feature", "sha" => "head-sha" }
    }
  end

  def fake_authentication
    token = RunDiff::Github::AppAuthentication::Token.new(
      value: "installation-token",
      expires_at: Time.utc(2026, 9, 4, 19, 30, 0)
    )

    Object.new.tap do |authentication|
      authentication.define_singleton_method(:installation_token) do |installation_id:|
        raise "unexpected installation" unless installation_id == 123

        token
      end
    end
  end

  def sequence_client(responses)
    queue = responses.dup
    Object.new.tap do |client|
      client.define_singleton_method(:fetch) do |repository:, number:|
        raise "unexpected repository" unless repository == "rundiff/rundiff"
        raise "unexpected pull request" unless number == 36

        queue.shift || raise("unexpected extra fetch")
      end
    end
  end

  def counting_publisher
    Struct.new(:calls, :infra_calls, :failure_classes) do
      def call(execution:, payload:)
        raise "missing execution" unless execution
        raise "missing payload" unless payload

        self.calls += 1
        { check: :created, comment: :created }
      end

      def infra_failure(execution:, error: nil, error_class: nil)
        raise "missing execution" unless execution

        self.infra_calls += 1
        failure_classes << (error_class || error.class.to_s)
        { check: :created, comment: :created }
      end
    end.new(0, 0, [])
  end
end
