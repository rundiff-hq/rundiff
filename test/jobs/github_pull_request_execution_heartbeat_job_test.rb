require "test_helper"

class GithubPullRequestExecutionHeartbeatJobTest < ActiveJob::TestCase
  test "renews the current running attempt and schedules the next heartbeat" do
    now = Time.utc(2026, 9, 5, 0, 30, 0)
    execution = create_running_execution(now:)

    with_database_clock(now + 10) do
      travel_to(now + 10) do
        assert_enqueued_jobs 1, only: GithubPullRequestExecutionHeartbeatJob do
          GithubPullRequestExecutionHeartbeatJob.perform_now(execution.execution_id, execution.attempt_count)
        end
      end
    end

    execution.reload
    assert_equal now + 10, execution.heartbeat_at
    assert execution.lease_expires_at > now + 10
  end

  test "renews a finalizing attempt until it reaches a terminal outcome" do
    now = Time.utc(2026, 9, 5, 0, 30, 0)
    execution = create_running_execution(now:)
    execution.begin_finalization!(attempt_number: execution.attempt_count, now: now + 5)

    with_database_clock(now + 10) do
      travel_to(now + 10) do
        assert_enqueued_jobs 1, only: GithubPullRequestExecutionHeartbeatJob do
          GithubPullRequestExecutionHeartbeatJob.perform_now(execution.execution_id, execution.attempt_count)
        end
      end
    end

    execution.reload
    assert_equal "finalizing", execution.status
    assert_equal now + 10, execution.heartbeat_at
  end

  test "does not renew or reschedule a previous attempt" do
    now = Time.utc(2026, 9, 5, 0, 30, 0)
    execution = create_running_execution(now:)
    original_heartbeat = execution.heartbeat_at
    original_lease = execution.lease_expires_at

    assert_no_enqueued_jobs only: GithubPullRequestExecutionHeartbeatJob do
      GithubPullRequestExecutionHeartbeatJob.perform_now(execution.execution_id, execution.attempt_count + 1)
    end

    execution.reload
    assert_equal original_heartbeat, execution.heartbeat_at
    assert_equal original_lease, execution.lease_expires_at
  end

  test "stops after the execution becomes terminal" do
    now = Time.utc(2026, 9, 5, 0, 30, 0)
    execution = create_running_execution(now:)
    execution.fail!(RuntimeError.new("worker stopped"))

    assert_no_enqueued_jobs only: GithubPullRequestExecutionHeartbeatJob do
      GithubPullRequestExecutionHeartbeatJob.perform_now(execution.execution_id, execution.attempt_count)
    end
  end

  test "stops after cancellation" do
    now = Time.utc(2026, 9, 5, 0, 30, 0)
    execution = create_running_execution(now:)
    execution.cancel!(attempt_number: execution.attempt_count, reason: "superseded", now: now + 5)

    assert_no_enqueued_jobs only: GithubPullRequestExecutionHeartbeatJob do
      GithubPullRequestExecutionHeartbeatJob.perform_now(execution.execution_id, execution.attempt_count)
    end

    execution.reload
    assert_equal "cancelled", execution.status
    assert_equal "cancelled", execution.outcome
  end

  private

  def create_running_execution(now:)
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(32)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {}
    )
    execution.claim!(now:)
    execution
  end
end
