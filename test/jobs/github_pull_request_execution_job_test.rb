require "test_helper"

class GithubPullRequestExecutionJobTest < ActiveJob::TestCase
  class TestJob < GithubPullRequestExecutionJob
    attr_accessor :authentication_override, :client_override, :executor_job_override, :publisher_override

    private

    def app_authentication
      authentication_override
    end

    def pull_request_client(token:)
      raise "unexpected token" unless token == "installation-token"

      client_override
    end

    def executor_job_class
      executor_job_override
    end

    def execution_publisher(token:)
      raise "unexpected publish token" unless token == "installation-token"

      publisher_override
    end
  end

  test "claims a current execution and dispatches a serialized portable request" do
    execution = create_execution
    dispatcher = counting_executor_job
    publisher = counting_publisher

    perform_job(
      execution:,
      client: sequence_client([ current_pull_request ]),
      dispatcher:,
      publisher:
    )

    execution.reload
    request = RunDiff::Executor::Request.from_h(dispatcher.payloads.first)
    assert_equal "running", execution.status
    assert_equal 1, execution.attempt_count
    assert_equal 1, dispatcher.payloads.length
    assert_equal execution.execution_id, request.execution_id
    assert_equal 1, request.attempt_number
    refute_includes request.context, "installation_id"
    refute_includes request.context, "delivery_id"
    assert_equal 0, publisher.infra_calls
  end

  test "github actions orchestrator leaves the live attempt for external claim without blind heartbeats" do
    previous = ENV["RUNDIFF_EXECUTION_ORCHESTRATOR"]
    ENV["RUNDIFF_EXECUTION_ORCHESTRATOR"] = "github_actions"

    execution = create_execution
    dispatcher = counting_executor_job

    assert_no_enqueued_jobs(only: GithubPullRequestExecutionHeartbeatJob) do
      perform_job(
        execution:,
        client: sequence_client([ current_pull_request ]),
        dispatcher:,
        publisher: counting_publisher
      )
    end

    assert_equal "running", execution.reload.status
    assert_equal 1, execution.attempt_count
    assert_empty dispatcher.payloads
  ensure
    ENV["RUNDIFF_EXECUTION_ORCHESTRATOR"] = previous
  end

  test "ignores a stale head before executor dispatch" do
    execution = create_execution
    stale = current_pull_request.deep_dup
    stale["head"]["sha"] = "newer-head"
    dispatcher = counting_executor_job

    perform_job(
      execution:,
      client: sequence_client([ stale ]),
      dispatcher:,
      publisher: counting_publisher
    )

    assert_equal "ignored", execution.reload.status
    assert_equal "stale", execution.outcome
    assert_equal "stale_head", execution.failure
    assert_empty dispatcher.payloads
  end

  test "classifies dispatch failure as infrastructure failure" do
    execution = create_execution
    publisher = counting_publisher

    assert_raises(RuntimeError) do
      perform_job(
        execution:,
        client: sequence_client([ current_pull_request, current_pull_request ]),
        dispatcher: failing_executor_job(RuntimeError.new("queue unavailable")),
        publisher:
      )
    end

    execution.reload
    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
    assert_equal 1, execution.attempt_count
    assert_match(/queue unavailable/, execution.failure)
    assert_equal 1, publisher.infra_calls
  end

  private

  def perform_job(execution:, client:, dispatcher:, publisher:)
    job = TestJob.new
    job.authentication_override = fake_authentication
    job.client_override = client
    job.executor_job_override = dispatcher
    job.publisher_override = publisher
    job.perform(execution.id)
  end

  def create_execution
    RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(32)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 31,
        "installation_id" => 123,
        "delivery_id" => "control-plane-only",
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    )
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
        raise "unexpected pull request" unless number == 31

        queue.shift || raise("unexpected extra fetch")
      end
    end
  end

  def counting_executor_job
    Struct.new(:payloads) do
      def perform_later(payload)
        payloads << payload
      end
    end.new([])
  end

  def failing_executor_job(error)
    Object.new.tap do |dispatcher|
      dispatcher.define_singleton_method(:perform_later) { |_payload| raise error }
    end
  end

  def counting_publisher
    Struct.new(:infra_calls) do
      def infra_failure(execution:, error:)
        raise "missing execution" unless execution
        raise "missing error" unless error

        self.infra_calls += 1
        { check: :created, comment: :created }
      end
    end.new(0)
  end
end
