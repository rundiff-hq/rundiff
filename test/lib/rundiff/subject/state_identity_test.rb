require "test_helper"

class RunDiffSubjectStateIdentityTest < ActiveSupport::TestCase
  Execution = Data.define(:execution_id)

  test "preserves the existing one-shot state suffix" do
    identity = RunDiff::Subject::StateIdentity.for(
      execution: Execution.new("github-abcdef1234567890"),
      role: "base"
    )

    assert_equal "abcdef123456_base", identity.suffix
  end

  test "adds an explicit sample index without overloading the role" do
    identity = RunDiff::Subject::StateIdentity.for(
      execution: Execution.new("github-abcdef1234567890"),
      role: "candidate",
      sample_index: 3
    )

    assert_equal "candidate", identity.role
    assert_equal 3, identity.sample_index
    assert_equal "abcdef123456_candidate_s3", identity.suffix
  end

  test "rejects ambiguous or unsafe state identities" do
    assert_raises(ArgumentError) do
      RunDiff::Subject::StateIdentity.new(
        execution_id: "",
        role: "base"
      )
    end

    assert_raises(ArgumentError) do
      RunDiff::Subject::StateIdentity.new(
        execution_id: "github-abcdef1234567890",
        role: "base/sample"
      )
    end

    assert_raises(ArgumentError) do
      RunDiff::Subject::StateIdentity.new(
        execution_id: "github-abcdef1234567890",
        role: "base",
        sample_index: 0
      )
    end
  end
end
