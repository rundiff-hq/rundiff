require "test_helper"

class RunDiffExecutorRepositoryCapabilityTest < ActiveSupport::TestCase
  test "parses a bearer repository capability" do
    capability = RunDiff::Executor::RepositoryCapability.from_header("Bearer clone-token")

    assert_equal "clone-token", capability.token
    assert_equal "Bearer clone-token", capability.authorization_header
    assert_equal "#<RunDiff::Executor::RepositoryCapability token=[FILTERED]>", capability.inspect
  end

  test "returns nil for an absent repository capability" do
    assert_nil RunDiff::Executor::RepositoryCapability.from_header(nil)
    assert_nil RunDiff::Executor::RepositoryCapability.from_header("")
  end

  test "rejects malformed repository capability authorization" do
    error = assert_raises(ArgumentError) do
      RunDiff::Executor::RepositoryCapability.from_header("Basic clone-token")
    end

    assert_equal "Invalid repository capability authorization", error.message
  end
end
