require "test_helper"

class RunDiffExecutorRequestTest < ActiveSupport::TestCase
  test "acquires a new idempotent request and completes only the active claim" do
    now = Time.utc(2026, 9, 4, 21, 40, 0)
    acquisition = acquire(now:)

    assert_equal :execute, acquisition.state
    assert_equal "processing", acquisition.record.status
    assert acquisition.claim_token
    assert_equal now + 60, acquisition.record.lease_expires_at

    result = RunDiff::Executor::Result.success("result" => { "decision" => "allow" }).to_h
    assert acquisition.record.complete_claim!(
      claim_token: acquisition.claim_token,
      result_payload: result,
      now: now + 10
    )

    record = acquisition.record.reload
    assert_equal "completed", record.status
    assert_equal result, record.result
    assert_nil record.claim_token
    assert_nil record.lease_expires_at
  end

  test "uses database-authoritative time instead of executor host wall clock by default" do
    database_now = Time.utc(2026, 9, 5, 0, 50, 0)

    first = with_database_clock(database_now) do
      travel_to(database_now + 12.hours) do
        RunDiffExecutorRequest.acquire!(
          idempotency_key: "execution:clock",
          request_payload:,
          lease_seconds: 60
        )
      end
    end

    assert_equal :execute, first.state
    assert_equal database_now, first.record.started_at
    assert_equal database_now + 60, first.record.lease_expires_at

    duplicate = with_database_clock(database_now + 30) do
      travel_to(database_now + 1.day) do
        RunDiffExecutorRequest.acquire!(
          idempotency_key: "execution:clock",
          request_payload:,
          lease_seconds: 60
        )
      end
    end
    assert_equal :in_progress, duplicate.state

    reclaimed = with_database_clock(database_now + 61) do
      travel_to(database_now - 1.day) do
        RunDiffExecutorRequest.acquire!(
          idempotency_key: "execution:clock",
          request_payload:,
          lease_seconds: 60
        )
      end
    end

    assert_equal :execute, reclaimed.state
    refute_equal first.claim_token, reclaimed.claim_token
    assert_equal database_now + 121, reclaimed.record.lease_expires_at
  end

  test "returns a completed result for the same request without another claim" do
    now = Time.utc(2026, 9, 4, 21, 40, 0)
    first = acquire(now:)
    first.record.complete_claim!(
      claim_token: first.claim_token,
      result_payload: RunDiff::Executor::Result.success({}).to_h,
      now: now + 1
    )

    duplicate = acquire(now: now + 2)

    assert_equal :completed, duplicate.state
    assert_nil duplicate.claim_token
  end

  test "reports an in-progress duplicate while the claim lease is live" do
    now = Time.utc(2026, 9, 4, 21, 40, 0)
    first = acquire(now:)
    duplicate = acquire(now: now + 30)

    assert_equal :execute, first.state
    assert_equal :in_progress, duplicate.state
    assert_nil duplicate.claim_token
  end

  test "reclaims an expired request with a new claim token" do
    now = Time.utc(2026, 9, 4, 21, 40, 0)
    first = acquire(now:)
    reclaimed = acquire(now: now + 61)

    assert_equal :execute, reclaimed.state
    refute_equal first.claim_token, reclaimed.claim_token
    assert_equal now + 121, reclaimed.record.lease_expires_at

    refute first.record.complete_claim!(
      claim_token: first.claim_token,
      result_payload: RunDiff::Executor::Result.success({}).to_h,
      now: now + 62
    )
  end

  test "cancels an active claim and prevents its late result from completing" do
    now = Time.utc(2026, 9, 5, 0, 50, 0)
    first = acquire(now:)

    cancellation = RunDiffExecutorRequest.cancel!(
      idempotency_key: "execution:1",
      reason: "control_plane_cancelled",
      now: now + 10
    )

    assert_equal :cancelled, cancellation.state
    assert_equal "cancelled", cancellation.record.status
    assert_equal "control_plane_cancelled", cancellation.record.cancellation_reason
    assert_equal now + 10, cancellation.record.cancelled_at
    assert_nil cancellation.record.claim_token
    assert_nil cancellation.record.lease_expires_at
    refute first.record.complete_claim!(
      claim_token: first.claim_token,
      result_payload: RunDiff::Executor::Result.success({}).to_h,
      now: now + 11
    )

    duplicate = acquire(now: now + 12)
    assert_equal :cancelled, duplicate.state
    assert_nil duplicate.claim_token
  end

  test "records cancellation before work arrives so later acquisition cannot start" do
    now = Time.utc(2026, 9, 5, 0, 50, 0)

    cancellation = RunDiffExecutorRequest.cancel!(
      idempotency_key: "execution:1",
      reason: "superseded",
      now:
    )
    acquisition = acquire(now: now + 1)

    assert_equal :cancelled, cancellation.state
    assert_equal :cancelled, acquisition.state
    assert_equal RunDiffExecutorRequest::CANCELLED_BEFORE_REQUEST_DIGEST, acquisition.record.request_digest
    assert_equal({}, acquisition.record.request_payload)
    assert_equal "superseded", acquisition.record.cancellation_reason
  end

  test "does not cancel a completed request" do
    now = Time.utc(2026, 9, 5, 0, 50, 0)
    first = acquire(now:)
    first.record.complete_claim!(
      claim_token: first.claim_token,
      result_payload: RunDiff::Executor::Result.success({}).to_h,
      now: now + 1
    )

    cancellation = RunDiffExecutorRequest.cancel!(
      idempotency_key: "execution:1",
      now: now + 2
    )

    assert_equal :completed, cancellation.state
    assert_equal "completed", cancellation.record.status
  end

  test "rejects reuse of an idempotency key for different request content" do
    now = Time.utc(2026, 9, 4, 21, 40, 0)
    acquire(now:)
    changed = request_payload.merge("candidate_sha" => "different-head")

    assert_raises(RunDiffExecutorRequest::DigestMismatch) do
      RunDiffExecutorRequest.acquire!(
        idempotency_key: "execution:1",
        request_payload: changed,
        now: now + 1,
        lease_seconds: 60
      )
    end
  end

  test "canonical request digests ignore hash key ordering" do
    first = {
      "b" => { "y" => 2, "x" => 1 },
      "a" => [ { "d" => 4, "c" => 3 } ]
    }
    second = {
      "a" => [ { "c" => 3, "d" => 4 } ],
      "b" => { "x" => 1, "y" => 2 }
    }

    assert_equal RunDiffExecutorRequest.digest_for(first), RunDiffExecutorRequest.digest_for(second)
  end

  private

  def acquire(now:)
    RunDiffExecutorRequest.acquire!(
      idempotency_key: "execution:1",
      request_payload:,
      now:,
      lease_seconds: 60
    )
  end

  def request_payload
    {
      "schema_version" => "1",
      "execution_id" => "github-123",
      "scenario_id" => "scenario",
      "baseline_sha" => "base",
      "candidate_sha" => "head",
      "attempt_number" => 1,
      "context" => {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 40,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    }
  end
end
