require "test_helper"

class RunDiffExecutorDispatchWorkflowTest < ActiveSupport::TestCase
  test "dependency cache action persists the executor cache root" do
    workflow = File.read(Rails.root.join(".github/workflows/rundiff-executor-dispatch.yml"))

    cache_root = "${{ github.workspace }}/tmp/rundiff-dependency-cache"

    assert_includes workflow, "RUNDIFF_DEPENDENCY_CACHE_ROOT: #{cache_root}"
    assert_includes workflow, "path: #{cache_root}"
    refute_includes workflow, "path: ${{ runner.temp }}/rundiff-dependency-cache"
  end
end
