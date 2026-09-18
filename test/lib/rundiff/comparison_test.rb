require "test_helper"

class RunDiffComparisonTest < ActiveSupport::TestCase
  test "compares one baseline with many candidates and ranks healthier behavior first" do
    baseline = { id: "main", measurements: measurements(sql_queries: 10, duration_ms: 100) }
    candidates = [
      { id: "attempt-slow", measurements: measurements(sql_queries: 30, duration_ms: 180) },
      { id: "attempt-stable", measurements: measurements(sql_queries: 10, duration_ms: 105) }
    ]

    comparison = RunDiff::Comparison.call(baseline:, candidates:)

    assert_equal 2, comparison.fetch("candidates").size
    assert_equal [ "attempt-stable", "attempt-slow" ], comparison.fetch("ranking")
    assert_equal "allow", comparison.fetch("candidates")[1].fetch("result").fetch("merge_recommendation")
    assert_equal "block", comparison.fetch("candidates")[0].fetch("result").fetch("merge_recommendation")
  end

  private

  def measurements(sql_queries:, duration_ms:)
    {
      duration_ms:,
      sql_queries:,
      background_jobs: 1,
      emails: 1,
      http_requests: 1,
      errors: 0
    }
  end
end
