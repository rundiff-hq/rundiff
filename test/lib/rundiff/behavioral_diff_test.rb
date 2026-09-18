require "test_helper"

class RunDiffBehavioralDiffTest < ActiveSupport::TestCase
  test "detects regressions while functional outcome may still pass" do
    result = RunDiff::BehavioralDiff.call(
      baseline: { duration_ms: 820, sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 11, errors: 0 },
      candidate: { duration_ms: 1460, sql_queries: 47, background_jobs: 3, emails: 2, http_requests: 11, errors: 0 }
    )

    assert_equal "regression", result.fetch("decision")
    assert_equal "block", result.fetch("merge_recommendation")

    reason_codes = result.fetch("findings").map { |finding| finding.fetch("reason_code") }
    assert_includes reason_codes, "PERFORMANCE_REGRESSION"
    assert_includes reason_codes, "DATABASE_QUERY_REGRESSION"
    assert_includes reason_codes, "SIDE_EFFECT_CHANGED"
  end

  test "ignores large percentage timing changes below the absolute noise floor" do
    baseline = { duration_ms: 28.8, sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 1, errors: 0 }
    candidate = { duration_ms: 35.1, sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 1, errors: 0 }

    result = RunDiff::BehavioralDiff.call(baseline:, candidate:)
    duration = result.fetch("signals").fetch("duration_ms")

    assert_equal 21.9, duration.fetch("delta_percent")
    assert_equal 6.3, duration.fetch("delta").round(1)
    assert_not duration.fetch("regression")
    assert_equal "no_regression", result.fetch("decision")
    assert_equal "allow", result.fetch("merge_recommendation")
  end

  test "requires both absolute and percentage thresholds for performance" do
    baseline = { duration_ms: 100, sql_queries: 0, background_jobs: 0, emails: 0, http_requests: 0, errors: 0 }
    candidate = { duration_ms: 125, sql_queries: 0, background_jobs: 0, emails: 0, http_requests: 0, errors: 0 }

    result = RunDiff::BehavioralDiff.call(baseline:, candidate:)

    assert result.fetch("signals").fetch("duration_ms").fetch("regression")
    finding = result.fetch("findings").first
    assert_equal "PERFORMANCE_REGRESSION", finding.fetch("reason_code")
    assert_not finding.fetch("blocking")
    assert_equal "single_sample_timing", finding.fetch("confidence")
    assert_equal "review", result.fetch("merge_recommendation")
  end

  test "keeps timing-only single-sample regressions review-only" do
    baseline = {
      duration_ms: 70.0,
      dispatch_wait_ms: 162.4,
      sql_queries: 17,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }
    candidate = {
      duration_ms: 93.7,
      dispatch_wait_ms: 203.1,
      sql_queries: 17,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }

    result = RunDiff::BehavioralDiff.call(baseline:, candidate:)

    assert_equal "regression", result.fetch("decision")
    assert_equal "review", result.fetch("merge_recommendation")
    assert_equal(
      %w[PERFORMANCE_REGRESSION DISPATCH_WAIT_REGRESSION],
      result.fetch("findings").map { |finding| finding.fetch("reason_code") }
    )
    assert result.fetch("findings").all? { |finding| finding.fetch("blocking") == false }
    assert(result.fetch("findings").all? do |finding|
      finding.fetch("confidence") == "single_sample_timing"
    end)
  end

  test "deterministic regression still blocks when timing is also noisy" do
    baseline = {
      duration_ms: 70.0,
      dispatch_wait_ms: 162.4,
      sql_queries: 17,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }
    candidate = {
      duration_ms: 93.7,
      dispatch_wait_ms: 203.1,
      sql_queries: 30,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }

    result = RunDiff::BehavioralDiff.call(baseline:, candidate:)

    assert_equal "block", result.fetch("merge_recommendation")
    sql = result.fetch("findings").find { |finding| finding.fetch("signal") == "sql_queries" }
    assert sql.fetch("blocking")
    assert_equal "deterministic", sql.fetch("confidence")
    assert_equal "DATABASE_QUERY_REGRESSION", result.dig("recommended_action", "reason_code")
  end

  test "marks every latency and CPU timing policy non-blocking until sampling exists" do
    timing_signals = %w[
      duration_ms
      thread_cpu_ms
      queue_wait_ms
      dispatch_wait_ms
      worker_wall_ms
      worker_thread_cpu_ms
    ]

    timing_signals.each do |signal|
      policy = RunDiff::BehavioralDiff::SIGNALS.fetch(signal)
      assert_equal false, policy.fetch(:blocking), signal
      assert_equal "single_sample_timing", policy.fetch(:confidence), signal
    end

    assert RunDiff::BehavioralDiff::SIGNALS.fetch("sql_queries").fetch(:blocking, true)
    assert_equal(
      "deterministic",
      RunDiff::BehavioralDiff::SIGNALS.fetch("sql_queries").fetch(:confidence, "deterministic")
    )
  end

  test "classifies low CPU ratio as wait bound" do
    result = RunDiff::BehavioralDiff.call(
      baseline: { duration_ms: 800, thread_cpu_ms: 70, worker_wall_ms: 400, worker_thread_cpu_ms: 50 },
      candidate: { duration_ms: 1_000, thread_cpu_ms: 80, worker_wall_ms: 600, worker_thread_cpu_ms: 60 }
    )

    assert_equal "wait_bound", result.dig("runtime_diagnosis", "request", "baseline", "classification")
    assert_equal 8.8, result.dig("runtime_diagnosis", "request", "baseline", "cpu_ratio_percent")
    assert_equal "wait_bound", result.dig("runtime_diagnosis", "request", "candidate", "classification")
    assert_equal "wait_bound", result.dig("runtime_diagnosis", "worker", "candidate", "classification")
  end

  test "detects worker thread CPU regression above the noise floor" do
    result = RunDiff::BehavioralDiff.call(
      baseline: { worker_wall_ms: 100, worker_process_cpu_ms: 24, worker_thread_cpu_ms: 20 },
      candidate: { worker_wall_ms: 110, worker_process_cpu_ms: 48, worker_thread_cpu_ms: 45 }
    )

    cpu_signal = result.fetch("signals").fetch("worker_thread_cpu_ms")
    process_cpu_signal = result.fetch("signals").fetch("worker_process_cpu_ms")

    assert cpu_signal.fetch("regression")
    assert_not process_cpu_signal.fetch("decision_relevant")
    assert_not process_cpu_signal.fetch("regression")
    assert_equal "CPU_TIME_REGRESSION", result.fetch("findings").first.fetch("reason_code")
    assert_equal "review", result.fetch("merge_recommendation")
  end

  test "treats a newly introduced optional CPU probe as unavailable instead of zero" do
    result = RunDiff::BehavioralDiff.call(
      baseline: { duration_ms: 100, sql_queries: 1, background_jobs: 0, emails: 0, http_requests: 0, errors: 0 },
      candidate: {
        duration_ms: 100,
        process_cpu_ms: 20,
        thread_cpu_ms: 18,
        worker_wall_ms: 50,
        worker_process_cpu_ms: 10,
        worker_thread_cpu_ms: 9,
        sql_queries: 1,
        background_jobs: 0,
        emails: 0,
        http_requests: 0,
        errors: 0
      }
    )

    thread_cpu = result.fetch("signals").fetch("thread_cpu_ms")
    worker_wall = result.fetch("signals").fetch("worker_wall_ms")

    assert_not thread_cpu.fetch("available")
    assert_nil thread_cpu.fetch("baseline")
    assert_equal 18, thread_cpu.fetch("candidate")
    assert_equal "n/a", thread_cpu.fetch("display_delta")
    assert_not thread_cpu.fetch("regression")
    assert_not worker_wall.fetch("available")
    assert_equal "unknown", result.dig("runtime_diagnosis", "request", "baseline", "classification")
    assert_equal "unknown", result.dig("runtime_diagnosis", "request", "candidate", "classification")
    assert_equal "allow", result.fetch("merge_recommendation")
  end

  test "allows equivalent behavior" do
    measurements = { duration_ms: 820, sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 11, errors: 0 }
    result = RunDiff::BehavioralDiff.call(baseline: measurements, candidate: measurements)

    assert_equal "no_regression", result.fetch("decision")
    assert_equal "allow", result.fetch("merge_recommendation")
  end
end
