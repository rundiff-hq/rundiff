require "test_helper"

class ProductionLabTimingSummaryTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/production-lab")

  test "prints only structured RunDiff stage timing lines on successful runs" do
    script = SCRIPT.read

    assert_includes script, "logs --no-color control-plane control-plane-worker executor"
    assert_includes(
      script,
      "grep -E 'RunDiff execution stage .*execution_id=.*stage=.*elapsed_ms=.*outcome='"
    )

    summary_call = "dump_timing_summary\n\necho \"production_lab_gate=passed\""
    assert_includes script, summary_call
  end

  test "keeps full service log dump failure-only" do
    script = SCRIPT.read

    cleanup_start = script.index("cleanup() {")
    cleanup_end = script.index("\n}\ntrap cleanup", cleanup_start)
    assert cleanup_start
    assert cleanup_end

    cleanup = script[cleanup_start..cleanup_end]
    assert_includes cleanup, 'if [[ $exit_code -ne 0 ]]'
    assert_includes cleanup, '"${COMPOSE[@]}" logs --no-color || true'
  end
end
