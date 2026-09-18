require "test_helper"

class RunDiffExecutionTest < ActiveSupport::TestCase
  test "claims a queued execution once, increments attempts, and creates a lease" do
    execution = create_execution
    now = Time.utc(2026, 9, 4, 20, 0, 0)

    assert execution.claim!(now:, lease_seconds: 120)
    assert_equal "running", execution.status
    assert_equal 1, execution.attempt_count
    assert_equal now, execution.started_at
    assert_equal now, execution.heartbeat_at
    assert_equal now + 120, execution.lease_expires_at
    refute execution.claim!(now: now + 1, lease_seconds: 120)
  end

  test "uses database-authoritative time instead of host wall clock by default" do
    execution = create_execution
    database_now = Time.utc(2026, 9, 5, 0, 40, 0)

    with_database_clock(database_now) do
      travel_to(database_now + 12.hours) do
        assert execution.claim!(lease_seconds: 120)
        assert_equal database_now, execution.started_at
        assert_equal database_now, execution.heartbeat_at
        assert_equal database_now + 120, execution.lease_expires_at
        refute execution.lease_expired?
      end
    end

    with_database_clock(database_now + 121) do
      travel_to(database_now - 12.hours) do
        assert execution.lease_expired?
        assert execution.expire_lease!
      end
    end

    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
  end

  test "renews only a live leased execution" do
    execution = create_execution
    now = Time.utc(2026, 9, 4, 20, 0, 0)
    execution.claim!(now:, lease_seconds: 120)

    assert execution.renew_lease!(now: now + 60, lease_seconds: 180)
    assert_equal now + 60, execution.heartbeat_at
    assert_equal now + 240, execution.lease_expires_at

    refute execution.renew_lease!(now: now + 241, lease_seconds: 180)
    assert execution.lease_expired?(at: now + 241)
  end

  test "atomically expires an overdue running lease as infrastructure failure" do
    execution = create_execution
    now = Time.utc(2026, 9, 4, 20, 0, 0)
    execution.claim!(now:, lease_seconds: 120)

    refute execution.expire_lease!(now: now + 119)
    assert execution.expire_lease!(now: now + 120)

    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
    assert_match(/RunDiff::Executor::LeaseExpired/, execution.failure)
    assert_nil execution.lease_expires_at
    assert execution.rerunnable?
    refute execution.expire_lease!(now: now + 121)
  end

  test "cancels only the exact active attempt without classifying infrastructure failure" do
    execution = create_execution
    now = Time.utc(2026, 9, 5, 0, 45, 0)
    execution.claim!(now:, lease_seconds: 120)

    refute execution.cancel!(attempt_number: 2, reason: "user_cancelled", now: now + 10)
    assert execution.cancel!(attempt_number: 1, reason: "user_cancelled", now: now + 10)

    execution.reload
    assert_equal "cancelled", execution.status
    assert_equal "cancelled", execution.outcome
    assert_equal "user_cancelled", execution.cancellation_reason
    assert_equal now + 10, execution.cancelled_at
    assert_equal now + 10, execution.finished_at
    assert_nil execution.lease_expires_at
    assert_nil execution.failure
    refute execution.rerunnable?
    refute execution.cancel!(attempt_number: 1, reason: "again", now: now + 11)
  end

  test "finalization creates a point of no return that cancellation cannot overwrite" do
    execution = create_execution
    now = Time.utc(2026, 9, 5, 0, 45, 0)
    execution.claim!(now:, lease_seconds: 120)

    refute execution.begin_finalization!(attempt_number: 2, now: now + 10)
    assert execution.begin_finalization!(attempt_number: 1, now: now + 10)
    assert_equal "finalizing", execution.status
    refute execution.cancel!(attempt_number: 1, reason: "too_late", now: now + 11)

    assert execution.renew_lease!(now: now + 20, lease_seconds: 120)
    assert_equal "finalizing", execution.status
  end

  test "stores the behavioral outcome on completion and closes the lease" do
    execution = create_execution
    execution.claim!

    payload = {
      "result" => { "decision" => "no_regression", "merge_recommendation" => "allow" },
      "run_id" => execution.execution_id
    }
    execution.complete!(payload)

    assert_equal "completed", execution.status
    assert_equal "no_regression", execution.decision
    assert_equal "allow", execution.outcome
    assert_equal payload, execution.result
    assert execution.finished_at
    assert_nil execution.lease_expires_at
  end

  test "classifies failures as rerunnable infrastructure failures" do
    execution = create_execution
    execution.claim!
    execution.fail!(RuntimeError.new("worker unavailable"))

    assert_equal "failed", execution.status
    assert_equal "infra_failure", execution.outcome
    assert_nil execution.lease_expires_at
    assert execution.rerunnable?

    assert execution.requeue!
    assert_equal "queued", execution.status
    assert_nil execution.outcome
    assert_nil execution.failure
    assert_nil execution.started_at
    assert_nil execution.heartbeat_at
    assert_nil execution.lease_expires_at
    assert_nil execution.finished_at
    assert_equal 1, execution.attempt_count

    assert execution.claim!
    assert_equal 2, execution.attempt_count
  end

  test "does not rerun completed behavioral outcomes" do
    execution = create_execution
    execution.claim!
    execution.complete!("result" => { "decision" => "review", "merge_recommendation" => "review" })

    refute execution.rerunnable?
    refute execution.requeue!
    assert_equal "completed", execution.status
    assert_equal "review", execution.outcome
  end

  test "classifies stale executions separately from infrastructure failures" do
    execution = create_execution
    execution.claim!
    execution.ignore!("stale_head_before_publish")

    assert_equal "ignored", execution.status
    assert_equal "stale", execution.outcome
    assert_nil execution.lease_expires_at
    refute execution.rerunnable?
  end

  private

  def create_execution
    RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(16)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {}
    )
  end
end
