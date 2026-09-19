require "test_helper"

class RunDiffGithubQueueStageRendererTest < ActiveSupport::TestCase
  test "renders a dispatch regression as post-eligibility wait" do
    payload = pair_payload(
      baseline: async_execution(queue_wait_ms: 130.0, scheduled_delay_ms: 0.0, dispatch_wait_ms: 130.0),
      candidate: async_execution(queue_wait_ms: 530.0, scheduled_delay_ms: 0.0, dispatch_wait_ms: 530.0)
    )

    comment = RunDiff::Github::CommentRenderer.markdown(payload:)
    check = RunDiff::Github::CheckRenderer.call(payload:)
    summary = check.fetch("summary")

    assert_equal "neutral", check.fetch("conclusion")
    assert_includes comment, "Eligible → worker start (dispatch)"
    assert_includes comment, "Regression source: dispatch wait after eligibility"
    assert_includes comment, "Scheduled delay | unchanged | 0.0%"
    assert_includes comment, "Eligible → worker start | +400.0 ms | 100.0%"
    assert_includes comment, "`DISPATCH_WAIT_REGRESSION`"
    assert_includes summary, "**Regression source:** dispatch wait after eligibility"
    assert_includes summary, "Eligible → worker start | +400.0 ms | 100.0%"
  end

  test "renders deliberate scheduling as observed intent without a regression" do
    payload = pair_payload(
      baseline: async_execution(queue_wait_ms: 130.0, scheduled_delay_ms: 0.0, dispatch_wait_ms: 130.0),
      candidate: async_execution(queue_wait_ms: 380.0, scheduled_delay_ms: 250.0, dispatch_wait_ms: 130.0)
    )

    comment = RunDiff::Github::CommentRenderer.markdown(payload:)
    check = RunDiff::Github::CheckRenderer.call(payload:)
    summary = check.fetch("summary")

    assert_equal "success", check.fetch("conclusion")
    assert_includes comment, "**ALLOW** - No behavioral regression detected."
    assert_includes comment, "Change source: declared scheduled delay"
    assert_includes comment, "Scheduled delay | +250.0 ms | 100.0%"
    assert_includes comment, "Eligible → worker start | unchanged | 0.0%"
    assert_includes summary, "**Change source:** declared scheduled delay"
    assert_not_includes comment, "DISPATCH_WAIT_REGRESSION"
  end

  private

  def pair_payload(baseline:, candidate:)
    RunDiff::ExecutionPair.call(baseline:, candidate:)
  end

  def async_execution(queue_wait_ms:, scheduled_delay_ms:, dispatch_wait_ms:)
    {
      "run_id" => "run-queue-stage",
      "scenario_id" => "scenario-queue-stage",
      "status" => "passed",
      "correlation_confirmed" => true,
      "measurements" => {
        "duration_ms" => 50.0,
        "thread_cpu_ms" => 20.0,
        "queue_wait_ms" => queue_wait_ms,
        "scheduled_delay_ms" => scheduled_delay_ms,
        "dispatch_wait_ms" => dispatch_wait_ms,
        "worker_wall_ms" => 0.1,
        "worker_thread_cpu_ms" => 0.1,
        "sql_queries" => 17,
        "background_jobs" => 1,
        "emails" => 1,
        "http_requests" => 1,
        "errors" => 0
      }
    }
  end
end
