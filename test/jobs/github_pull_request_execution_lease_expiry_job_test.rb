require "test_helper"

class GithubPullRequestExecutionLeaseExpiryJobTest < ActiveJob::TestCase
  class TestJob < GithubPullRequestExecutionLeaseExpiryJob
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

  test "expires an overdue execution and publishes an infrastructure failure" do
    now = Time.utc(2026, 9, 4, 20, 10, 0)
    execution = running_execution(now: now - 120, lease_seconds: 60)
    publisher = counting_publisher

    perform_job(
      execution:,
      expired_at: now,
      client: current_client,
      publisher:
    )

    execution.reload
    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
    assert_match(/RunDiff::Executor::LeaseExpired/, execution.failure)
    assert execution.rerunnable?
    assert_equal [ "RunDiff::Executor::LeaseExpired" ], publisher.failure_classes
  end

  test "expires an overdue finalizing execution" do
    now = Time.utc(2026, 9, 4, 20, 10, 0)
    execution = running_execution(now: now - 120, lease_seconds: 60)
    execution.update!(status: "finalizing")
    publisher = counting_publisher

    perform_job(
      execution:,
      expired_at: now,
      client: current_client,
      publisher:
    )

    execution.reload
    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
    assert_equal [ "RunDiff::Executor::LeaseExpired" ], publisher.failure_classes
  end

  test "does nothing when the lease was renewed before expiry finalization" do
    now = Time.utc(2026, 9, 4, 20, 10, 0)
    execution = running_execution(now: now - 120, lease_seconds: 60)
    execution.update!(lease_expires_at: now + 60, heartbeat_at: now)

    job = TestJob.new
    job.perform(execution.id, now)

    execution.reload
    assert_equal "running", execution.status
    assert_equal now + 60, execution.lease_expires_at
  end

  test "marks an expired execution stale instead of publishing against a moved pull request" do
    now = Time.utc(2026, 9, 4, 20, 10, 0)
    execution = running_execution(now: now - 120, lease_seconds: 60)
    stale = current_pull_request.deep_dup
    stale["head"]["sha"] = "new-head"
    publisher = counting_publisher

    perform_job(
      execution:,
      expired_at: now,
      client: client_for(stale),
      publisher:
    )

    execution.reload
    assert_equal "ignored", execution.status
    assert_equal "stale", execution.outcome
    assert_equal "stale_head_after_lease_expiry", execution.failure
    assert_empty publisher.failure_classes
  end

  test "can retry publication after the lease was already expired" do
    now = Time.utc(2026, 9, 4, 20, 10, 0)
    execution = running_execution(now: now - 120, lease_seconds: 60)
    assert execution.expire_lease!(now:)
    publisher = counting_publisher

    perform_job(
      execution:,
      expired_at: now,
      client: current_client,
      publisher:
    )

    assert_equal "failed", execution.reload.status
    assert_equal [ "RunDiff::Executor::LeaseExpired" ], publisher.failure_classes
  end

  private

  def perform_job(execution:, expired_at:, client:, publisher:)
    job = TestJob.new
    job.authentication_override = fake_authentication
    job.client_override = client
    job.publisher_override = publisher
    job.perform(execution.id, expired_at)
  end

  def running_execution(now:, lease_seconds:)
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(16)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 38,
        "installation_id" => 123
      }
    )
    execution.claim!(now:, lease_seconds:)
    execution
  end

  def current_pull_request
    {
      "base" => { "sha" => "base-sha" },
      "head" => { "sha" => "head-sha" }
    }
  end

  def current_client
    client_for(current_pull_request)
  end

  def client_for(pull_request)
    Object.new.tap do |client|
      client.define_singleton_method(:fetch) do |repository:, number:|
        raise "unexpected repository" unless repository == "rundiff/rundiff"
        raise "unexpected pull request" unless number == 38

        pull_request
      end
    end
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

  def counting_publisher
    Struct.new(:failure_classes) do
      def infra_failure(execution:, error_class:)
        raise "missing execution" unless execution

        failure_classes << error_class
        { check: :created, comment: :created }
      end
    end.new([])
  end
end
