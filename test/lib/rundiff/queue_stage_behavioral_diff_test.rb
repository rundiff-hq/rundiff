require "test_helper"

class RunDiffQueueStageBehavioralDiffTest < ActiveSupport::TestCase
  test "treats deliberate scheduling as observed intent instead of queue regression" do
    result = RunDiff::BehavioralDiff.call(
      baseline: measurements(queue_wait_ms: 130.0, scheduled_delay_ms: 0.0, dispatch_wait_ms: 130.0),
      candidate: measurements(queue_wait_ms: 380.0, scheduled_delay_ms: 250.0, dispatch_wait_ms: 130.0)
    )

    assert_equal "no_regression", result.fetch("decision")
    assert_equal "allow", result.fetch("merge_recommendation")
    assert_not result.dig("signals", "queue_wait_ms", "decision_relevant")
    assert_not result.dig("signals", "scheduled_delay_ms", "decision_relevant")
    assert result.dig("signals", "dispatch_wait_ms", "decision_relevant")
    assert_not result.dig("signals", "dispatch_wait_ms", "regression")
    assert_equal "scheduled_delay_change", result.dig("runtime_diagnosis", "async_delta", "classification")
  end

  test "flags post-eligibility dispatch wait without double counting aggregate queue wait" do
    result = RunDiff::BehavioralDiff.call(
      baseline: measurements(queue_wait_ms: 130.0, scheduled_delay_ms: 0.0, dispatch_wait_ms: 130.0),
      candidate: measurements(queue_wait_ms: 530.0, scheduled_delay_ms: 0.0, dispatch_wait_ms: 530.0)
    )

    assert_equal "regression", result.fetch("decision")
    assert_equal "review", result.fetch("merge_recommendation")
    assert_not result.dig("signals", "queue_wait_ms", "decision_relevant")
    assert result.dig("signals", "dispatch_wait_ms", "regression")
    assert_equal [ "DISPATCH_WAIT_REGRESSION" ], result.fetch("findings").map { |finding| finding.fetch("reason_code") }
    assert_equal "dispatch_wait_regression", result.dig("runtime_diagnosis", "async_delta", "classification")
  end

  private

  def measurements(queue_wait_ms:, scheduled_delay_ms:, dispatch_wait_ms:)
    {
      duration_ms: 50.0,
      thread_cpu_ms: 20.0,
      queue_wait_ms:,
      scheduled_delay_ms:,
      dispatch_wait_ms:,
      worker_wall_ms: 0.1,
      worker_thread_cpu_ms: 0.1,
      sql_queries: 17,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }
  end
end
