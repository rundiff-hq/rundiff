require "test_helper"

class GithubCheckRunRerequestJobTest < ActiveJob::TestCase
  class FakeExecutionJob
    class << self
      attr_accessor :enqueued_ids

      def perform_later(execution_id)
        self.enqueued_ids ||= []
        enqueued_ids << execution_id
      end
    end
  end

  class TestJob < GithubCheckRunRerequestJob
    attr_accessor :authentication_override, :client_override

    private

    def app_authentication
      authentication_override
    end

    def pull_request_client(token:)
      raise "unexpected token" unless token == "installation-token"

      client_override
    end

    def execution_job_class
      FakeExecutionJob
    end
  end

  setup do
    FakeExecutionJob.enqueued_ids = []
  end

  test "requeues only an infra failure for the current base and head" do
    execution = create_execution
    mark_infra_failure(execution)
    delivery = create_delivery(execution:)

    perform_job(delivery:, pull_request: current_pull_request)

    assert_equal "completed", delivery.reload.status
    assert_equal "queued", execution.reload.status
    assert_nil execution.outcome
    assert_equal [ execution.id ], FakeExecutionJob.enqueued_ids
  end

  test "does not rerun a completed behavioral result" do
    execution = create_execution
    execution.claim!
    execution.complete!("result" => { "decision" => "review", "merge_recommendation" => "review" })
    delivery = create_delivery(execution:)

    perform_job(delivery:, pull_request: current_pull_request)

    assert_equal "ignored", delivery.reload.status
    assert_equal "execution_not_rerunnable", delivery.failure
    assert_equal "completed", execution.reload.status
    assert_empty FakeExecutionJob.enqueued_ids
  end

  test "does not rerun an old check after the pull request moves" do
    execution = create_execution
    mark_infra_failure(execution)
    delivery = create_delivery(execution:)
    moved = current_pull_request.deep_dup
    moved["head"]["sha"] = "new-head"

    perform_job(delivery:, pull_request: moved)

    assert_equal "ignored", delivery.reload.status
    assert_equal "stale_check_run", delivery.failure
    assert_equal "failed", execution.reload.status
    assert_equal "infra_failure", execution.outcome
    assert_empty FakeExecutionJob.enqueued_ids
  end

  private

  def perform_job(delivery:, pull_request:)
    job = TestJob.new
    job.authentication_override = fake_authentication
    job.client_override = fake_client(pull_request)
    job.perform(delivery.id)
  end

  def create_execution
    RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(16)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 34,
        "installation_id" => 123
      }
    )
  end

  def mark_infra_failure(execution)
    execution.claim!
    execution.fail!(RuntimeError.new("worker unavailable"))
  end

  def create_delivery(execution:)
    GithubWebhookDelivery.create!(
      delivery_id: "delivery-#{SecureRandom.hex(8)}",
      event: "check_run",
      action: "rerequested",
      installation_id: 123,
      repository: "rundiff/rundiff",
      head_sha: execution.candidate_sha,
      external_id: execution.execution_id
    )
  end

  def current_pull_request
    {
      "base" => { "sha" => "base-sha" },
      "head" => { "sha" => "head-sha" }
    }
  end

  def fake_authentication
    token = RunDiff::Github::AppAuthentication::Token.new(
      value: "installation-token",
      expires_at: Time.utc(2026, 9, 4, 21, 0, 0)
    )

    Object.new.tap do |authentication|
      authentication.define_singleton_method(:installation_token) do |installation_id:|
        raise "unexpected installation" unless installation_id == 123

        token
      end
    end
  end

  def fake_client(pull_request)
    Object.new.tap do |client|
      client.define_singleton_method(:fetch) do |repository:, number:|
        raise "unexpected repository" unless repository == "rundiff/rundiff"
        raise "unexpected pull request" unless number == 34

        pull_request
      end
    end
  end
end
