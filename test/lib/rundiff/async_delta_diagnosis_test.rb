require "test_helper"

class RunDiffAsyncDeltaDiagnosisTest < ActiveSupport::TestCase
  test "attributes queue-stage regression to enqueue-to-start delta for legacy evidence" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: 264.1, regression: true),
      worker_wall: signal(delta: 0.0)
    )

    assert_equal "enqueue_to_start_regression", result.fetch("classification")
    assert_equal 264.1, result.fetch("queue_wait_delta_ms")
    assert_equal 0.0, result.fetch("worker_wall_delta_ms")
    assert_equal 100.0, result.fetch("dominant_delta_share_percent")
  end

  test "separates deliberate scheduling from dispatch regression" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: 250.0),
      scheduled_delay: signal(delta: 250.0),
      dispatch_wait: signal(delta: 0.0),
      worker_wall: signal(delta: 0.0)
    )

    assert_equal "scheduled_delay_change", result.fetch("classification")
    assert_equal 250.0, result.fetch("scheduled_delay_delta_ms")
    assert_equal 0.0, result.fetch("dispatch_wait_delta_ms")
    assert_equal 100.0, result.fetch("scheduled_delay_delta_share_percent")
  end

  test "attributes post-eligibility growth to dispatch wait" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: 401.8),
      scheduled_delay: signal(delta: 0.0),
      dispatch_wait: signal(delta: 401.8, regression: true),
      worker_wall: signal(delta: 0.0)
    )

    assert_equal "dispatch_wait_regression", result.fetch("classification")
    assert_equal 401.8, result.fetch("dispatch_wait_delta_ms")
    assert_equal 100.0, result.fetch("dispatch_wait_delta_share_percent")
    assert_equal 0.0, result.fetch("worker_runtime_delta_share_percent")
  end

  test "attributes worker regression to worker runtime delta" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: 5.0),
      worker_wall: signal(delta: 145.0, regression: true)
    )

    assert_equal "worker_runtime_regression", result.fetch("classification")
    assert_equal 3.3, result.fetch("enqueue_to_start_delta_share_percent")
    assert_equal 96.7, result.fetch("dominant_delta_share_percent")
  end

  test "keeps substantial positive growth in both legacy stages as mixed" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: 60.0, regression: true),
      worker_wall: signal(delta: 40.0, regression: true)
    )

    assert_equal "mixed_async_regression", result.fetch("classification")
    assert_equal 60.0, result.fetch("enqueue_to_start_delta_share_percent")
    assert_equal 60.0, result.fetch("dominant_delta_share_percent")
  end

  test "does not invent a causal regression when async signals are stable" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: 8.0),
      worker_wall: signal(delta: -20.0)
    )

    assert_equal "no_async_regression", result.fetch("classification")
    assert_nil result.fetch("dominant_delta_share_percent")
  end

  test "returns unknown for capability mismatch" do
    result = RunDiff::AsyncDeltaDiagnosis.call(
      queue_wait: signal(delta: nil, available: false),
      worker_wall: signal(delta: 10.0)
    )

    assert_equal "unknown", result.fetch("classification")
    assert_nil result.fetch("positive_async_delta_ms")
  end

  test "behavioral diff exposes the dominant async regression source for legacy evidence" do
    result = RunDiff::BehavioralDiff.call(
      baseline: measurements(queue_wait_ms: 137.5, worker_wall_ms: 0.1),
      candidate: measurements(queue_wait_ms: 401.6, worker_wall_ms: 0.1)
    )

    diagnosis = result.dig("runtime_diagnosis", "async_delta")

    assert_equal "review", result.fetch("merge_recommendation")
    assert_equal "enqueue_to_start_regression", diagnosis.fetch("classification")
    assert_equal 264.1, diagnosis.fetch("queue_wait_delta_ms")
    assert_equal 0.0, diagnosis.fetch("worker_wall_delta_ms")
    assert_equal 100.0, diagnosis.fetch("dominant_delta_share_percent")
  end

  private

  def signal(delta:, regression: false, available: true)
    {
      "delta" => delta,
      "regression" => regression,
      "available" => available
    }
  end

  def measurements(queue_wait_ms:, worker_wall_ms:)
    {
      queue_wait_ms:,
      worker_wall_ms:,
      worker_thread_cpu_ms: 0.1,
      duration_ms: 50.0,
      thread_cpu_ms: 20.0,
      sql_queries: 17,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }
  end
end
