require "test_helper"

class RunDiffRailsQueueStageTimingTest < ActiveSupport::TestCase
  test "splits deliberate scheduling from dispatch wait" do
    enqueued_at = Time.utc(2026, 9, 4, 12, 0, 0)
    scheduled_at = enqueued_at + 0.25
    started_at = enqueued_at + 0.41

    timing = RunDiff::Rails::QueueStageTiming.call(enqueued_at:, scheduled_at:, started_at:)

    assert_equal 410.0, timing.fetch("queue_wait_ms")
    assert_equal 250.0, timing.fetch("scheduled_delay_ms")
    assert_equal 160.0, timing.fetch("dispatch_wait_ms")
  end

  test "accepts trusted duration inputs without wall clock subtraction" do
    timing = RunDiff::Rails::QueueStageTiming.call(
      queue_wait_ms: 410.0,
      scheduled_delay_ms: 250.0
    )

    assert_equal 410.0, timing.fetch("queue_wait_ms")
    assert_equal 250.0, timing.fetch("scheduled_delay_ms")
    assert_equal 160.0, timing.fetch("dispatch_wait_ms")
  end

  test "treats immediate jobs as pure dispatch wait" do
    enqueued_at = Time.utc(2026, 9, 4, 12, 0, 0)
    started_at = enqueued_at + 0.13

    timing = RunDiff::Rails::QueueStageTiming.call(enqueued_at:, started_at:)

    assert_equal 130.0, timing.fetch("queue_wait_ms")
    assert_equal 0.0, timing.fetch("scheduled_delay_ms")
    assert_equal 130.0, timing.fetch("dispatch_wait_ms")
  end

  test "caps declared scheduling at observed queue wait" do
    timing = RunDiff::Rails::QueueStageTiming.call(
      queue_wait_ms: 130.0,
      scheduled_delay_ms: 250.0
    )

    assert_equal 130.0, timing.fetch("queue_wait_ms")
    assert_equal 130.0, timing.fetch("scheduled_delay_ms")
    assert_equal 0.0, timing.fetch("dispatch_wait_ms")
  end

  test "never reports negative timing because of clock ordering" do
    enqueued_at = Time.utc(2026, 9, 4, 12, 0, 0)
    started_at = enqueued_at - 0.01

    timing = RunDiff::Rails::QueueStageTiming.call(enqueued_at:, started_at:)

    assert_equal 0.0, timing.fetch("queue_wait_ms")
    assert_equal 0.0, timing.fetch("scheduled_delay_ms")
    assert_equal 0.0, timing.fetch("dispatch_wait_ms")
  end
end
