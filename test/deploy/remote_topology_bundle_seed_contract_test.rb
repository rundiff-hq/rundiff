require "test_helper"

class RemoteTopologyBundleSeedContractTest < ActiveSupport::TestCase
  WORKFLOW = Rails.root.join(".github/workflows/ci.yml")

  test "mounts the trusted seed read-only only into the executor proof" do
    workflow = WORKFLOW.read

    assert_includes workflow, "docker volume create rundiff-topology-bundle-seed"
    assert_includes(
      workflow,
      "-v rundiff-topology-bundle-seed:/rundiff-bundle-seed:ro"
    )
    assert_includes(
      workflow,
      "-e RUNDIFF_SUBJECT_BUNDLE_SEED_ROOT=/rundiff-bundle-seed"
    )
    refute_includes(
      workflow,
      "-v rundiff-topology-bundle-seed:/rundiff-bundle-seed \\\n            -e RUNDIFF_SUBJECT_BUNDLE_SEED_ROOT"
    )
  end

  test "verifies read-only mount and always removes the seed volume" do
    workflow = WORKFLOW.read

    assert_includes workflow, "! touch /rundiff-bundle-seed/.write-test"
    assert_includes workflow, "docker volume rm -f rundiff-topology-bundle-seed || true"
  end
end
