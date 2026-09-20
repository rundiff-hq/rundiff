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

    rule_ids = result.fetch("findings").map { |finding| finding.fetch("rule_id") }
    assert_includes rule_ids, "performance.wall_time.regression"
    assert_includes rule_ids, "database.query.count.regression"
    assert_includes rule_ids, "side_effect.background_job.count.changed"
    assert_includes rule_ids, "side_effect.email.count.changed"

    database_finding = result.fetch("findings").find do |finding|
      finding.fetch("rule_id") == "database.query.count.regression"
    end
    assert_equal %w[database], database_finding.dig("facets", "domains")
    assert_equal %w[performance_efficiency], database_finding.dig("facets", "quality_dimensions")
    assert_equal %w[database io], database_finding.dig("facets", "resources")
    assert_equal "increase", database_finding.dig("facets", "change_kind")
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
    assert_equal "performance.wall_time.regression", finding.fetch("rule_id")
    assert_equal "block", result.fetch("merge_recommendation")
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
