require "test_helper"

class RunDiffDemoDogfoodRunnerTest < ActiveSupport::TestCase
  test "compares two real Rails executions and correlates their evidence" do
    payload = RunDiff::Demo::DogfoodRunner.call
    baseline = payload.dig("executions", "baseline")
    candidate = payload.dig("executions", "candidate")
    result = payload.fetch("result")

    assert_equal "passed", baseline.fetch("status")
    assert_equal "passed", candidate.fetch("status")
    assert baseline.fetch("correlation_confirmed")
    assert candidate.fetch("correlation_confirmed")

    assert_operator candidate.dig("measurements", "sql_queries"), :>, baseline.dig("measurements", "sql_queries")
    assert_operator candidate.dig("measurements", "background_jobs"), :>, baseline.dig("measurements", "background_jobs")
    assert_operator candidate.dig("measurements", "emails"), :>, baseline.dig("measurements", "emails")
    assert_equal "regression", result.fetch("decision")
    assert_equal "block", result.fetch("merge_recommendation")

    reason_codes = result.fetch("findings").map { |finding| finding.fetch("reason_code") }
    assert_includes reason_codes, "DATABASE_QUERY_REGRESSION"
    assert_includes reason_codes, "SIDE_EFFECT_CHANGED"
  end
end
