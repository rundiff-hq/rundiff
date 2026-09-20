<sub>require "test_helper"

class RunDiffRuleRegistryTest < ActiveSupport::TestCase
  test "provides stable dotted rule ids for current decision signals" do
    assert_equal "database.query.count.regression", RunDiff::RuleRegistry.rule_id_for("sql_queries")
    assert_equal "resource.cpu.time.regression", RunDiff::RuleRegistry.rule_id_for("thread_cpu_ms")
    assert_equal "side_effect.email.count.changed", RunDiff::RuleRegistry.rule_id_for("emails")
    assert_equal "runtime.error.new", RunDiff::RuleRegistry.rule_id_for("errors")
  end

  test "splits legacy side effect reason code by concrete signal" do
    assert_equal(
      "side_effect.background_job.count.changed",
      RunDiff::RuleRegistry.rule_id_for("background_jobs")
    )
    assert_equal(
      "side_effect.email.count.changed",
      RunDiff::RuleRegistry.rule_id_for("emails")
    )
  end

  test "keeps facets orthogonal instead of one category tree" do
    rule = RunDiff::RuleRegistry.fetch("http_requests")

    assert_equal %w[network external_dependency], rule.fetch(:domains)
    assert_equal %w[performance_efficiency reliability], rule.fetch(:quality_dimensions)
    assert_equal %w[network external_service], rule.fetch(:resources)
  end
end
</sub>