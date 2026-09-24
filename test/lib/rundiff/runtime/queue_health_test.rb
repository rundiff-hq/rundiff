require "test_helper"

class RunDiff::Runtime::QueueHealthTest < ActiveSupport::TestCase
  test "reports Solid Queue process and control queue diagnostics" do
    result = RunDiff::Runtime::QueueHealth.new.call

    assert_equal "available", result.fetch("status")
    assert_equal "solid_queue", result.fetch("adapter")
    assert_equal 60, result.fetch("heartbeat_window_seconds")
    assert_kind_of Integer, result.fetch("live_process_count")
    assert_kind_of Array, result.fetch("live_processes")

    %w[
      pending_control_jobs
      ready_control_jobs
      claimed_control_jobs
      failed_control_jobs
    ].each do |key|
      assert_kind_of Integer, result.fetch(key)
    end
  end
end
