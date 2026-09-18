require "test_helper"

class RunDiffSubjectSetupPlanTest < ActiveSupport::TestCase
  test "groups validated steps by lifecycle phase and serializes provenance" do
    plan = RunDiff::Subject::SetupPlan.new(
      framework: "rails",
      steps: [
        {
          phase: "bootstrap",
          operation: "ruby.bundle",
          provenance: "detected",
          details: { lockfile: "Gemfile.lock" }
        },
        {
          phase: "cleanup",
          operation: "subject.state_cleanup",
          provenance: "executor_default"
        }
      ],
      evidence: { gemfile: true }
    )

    assert_equal "ruby.bundle", plan.steps_for(:bootstrap).sole.operation
    assert_equal "detected", plan.to_h.dig("steps", 0, "provenance")
    assert_equal true, plan.to_h.dig("evidence", "gemfile")
  end

  test "rejects unsupported phases and provenance" do
    phase_error = assert_raises(RunDiff::Subject::SetupPlan::Error) do
      RunDiff::Subject::SetupPlan::Step.new(
        phase: "capture",
        operation: "rails.capture",
        provenance: "detected"
      )
    end
    assert_match(/Unsupported setup-plan phase/, phase_error.message)

    provenance_error = assert_raises(RunDiff::Subject::SetupPlan::Error) do
      RunDiff::Subject::SetupPlan::Step.new(
        phase: "bootstrap",
        operation: "ruby.bundle",
        provenance: "guessed"
      )
    end
    assert_match(/Unsupported setup-plan provenance/, provenance_error.message)
  end
end
