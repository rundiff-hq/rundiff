require "test_helper"

class RunDiffRailsInternalOperationTest < ActiveSupport::TestCase
  test "is active only inside guarded work and supports nesting" do
    assert_not RunDiff::Rails::InternalOperation.active?

    RunDiff::Rails::InternalOperation.call do
      assert RunDiff::Rails::InternalOperation.active?

      RunDiff::Rails::InternalOperation.call do
        assert RunDiff::Rails::InternalOperation.active?
      end

      assert RunDiff::Rails::InternalOperation.active?
    end

    assert_not RunDiff::Rails::InternalOperation.active?
  end

  test "restores state when guarded work raises" do
    assert_raises(RuntimeError) do
      RunDiff::Rails::InternalOperation.call do
        assert RunDiff::Rails::InternalOperation.active?
        raise "guard proof failure"
      end
    end

    assert_not RunDiff::Rails::InternalOperation.active?
  end
end
