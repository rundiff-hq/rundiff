require "test_helper"

class GithubPullRequestWebhookJobTest < ActiveJob::TestCase
  class FakeExecutionJob
    class << self
      attr_accessor :enqueued_ids

      def perform_later(execution_id)
        self.enqueued_ids ||= []
        enqueued_ids << execution_id
      end
    end
  end

  class TestJob < GithubPullRequestWebhookJob
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

  test "authenticates the installation and queues a durable current execution" do
    delivery = create_delivery(action: "synchronize")

    assert_difference("RunDiffExecution.count", 1) do
      perform_job(delivery:, head_sha: "head-sha")
    end

    execution = RunDiffExecution.last
    assert_equal "completed", delivery.reload.status
    assert_nil delivery.failure
    assert_equal "queued", execution.status
    assert_equal "github_pull_request", execution.source
    assert_equal "base-sha", execution.baseline_sha
    assert_equal "head-sha", execution.candidate_sha
    assert_equal "rundiff/rundiff", execution.context.fetch("repository")
    assert_equal 19, execution.context.fetch("pull_request_number")
    assert_equal [ execution.id ], FakeExecutionJob.enqueued_ids
  end

  test "re-enqueues the same base and head while the durable execution is still queued" do
    first = create_delivery(action: "synchronize")
    second = create_delivery(action: "ready_for_review")

    perform_job(delivery: first, head_sha: "head-sha")
    perform_job(delivery: second, head_sha: "head-sha")

    assert_equal 1, RunDiffExecution.count
    assert_equal 2, FakeExecutionJob.enqueued_ids.length
    assert_equal "completed", second.reload.status
  end

  test "authenticates but ignores a pull request edit" do
    delivery = create_delivery(action: "edited")
    perform_job(delivery:, head_sha: "head-sha")

    assert_equal "ignored", delivery.reload.status
    assert_equal "action_not_execution_trigger", delivery.failure
    assert_empty FakeExecutionJob.enqueued_ids
  end

  test "ignores a stale webhook head" do
    delivery = create_delivery(action: "synchronize")
    perform_job(delivery:, head_sha: "newer-head")

    assert_equal "ignored", delivery.reload.status
    assert_equal "stale_head", delivery.failure
    assert_empty FakeExecutionJob.enqueued_ids
  end

  private

  def perform_job(delivery:, head_sha:)
    job = TestJob.new
    job.authentication_override = fake_authentication
    job.client_override = fake_client(head_sha:)
    job.perform(delivery.id)
  end

  def create_delivery(action:)
    GithubWebhookDelivery.create!(
      delivery_id: "delivery-#{action}-#{SecureRandom.hex(4)}",
      event: "pull_request",
      action:,
      installation_id: 158_885_061,
      repository: "rundiff/rundiff",
      pull_request_number: 19,
      base_sha: "base-sha",
      head_sha: "head-sha"
    )
  end

  def fake_authentication
    token = RunDiff::Github::AppAuthentication::Token.new(
      value: "installation-token",
      expires_at: Time.utc(2026, 9, 4, 18, 30, 0)
    )

    Object.new.tap do |authentication|
      authentication.define_singleton_method(:installation_token) do |installation_id:|
        raise "unexpected installation" unless installation_id == 158_885_061

        token
      end
    end
  end

  def fake_client(head_sha:)
    Object.new.tap do |client|
      client.define_singleton_method(:fetch) do |repository:, number:|
        raise "unexpected repository" unless repository == "rundiff/rundiff"
        raise "unexpected pull request" unless number == 19

        {
          "base" => { "ref" => "main", "sha" => "base-sha" },
          "head" => {
            "ref" => "feature",
            "sha" => head_sha,
            "repo" => { "full_name" => "rundiff/rundiff" }
          }
        }
      end
    end
  end
end
