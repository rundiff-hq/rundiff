require "test_helper"
require "active_support/testing/time_helpers"

class RunDiffRailsQueueTimingContextTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  FakeJob = Data.define(:enqueued_at, :scheduled_at)

  test "captures declared scheduling as a duration at enqueue time" do
    enqueued_at = Time.utc(2026, 9, 5, 12, 0, 0)
    job = FakeJob.new(enqueued_at:, scheduled_at: enqueued_at + 0.25)

    context = RunDiff::Rails::QueueTimingContext.capture(
      job,
      clock_domain_id: "boot-a",
      monotonic_now: 100.0
    )

    assert_equal 1, context.fetch("version")
    assert_equal "boot-a", context.fetch("clock_domain_id")
    assert_equal 100.0, context.fetch("enqueued_monotonic_seconds")
    assert_equal 250.0, context.fetch("scheduled_delay_ms")
  end

  test "measures queue wait from monotonic time despite positive or negative wall clock skew" do
    context = {
      "version" => 1,
      "clock_domain_id" => "boot-a",
      "enqueued_monotonic_seconds" => 100.0,
      "scheduled_delay_ms" => 250.0
    }

    positive_skew = travel_to(Time.utc(2036, 1, 1)) do
      RunDiff::Rails::QueueTimingContext.measure(
        context,
        clock_domain_id: "boot-a",
        monotonic_now: 100.41
      )
    end
    negative_skew = travel_to(Time.utc(2016, 1, 1)) do
      RunDiff::Rails::QueueTimingContext.measure(
        context,
        clock_domain_id: "boot-a",
        monotonic_now: 100.41
      )
    end

    assert_equal positive_skew, negative_skew
    assert_equal 410.0, positive_skew.fetch("queue_wait_ms")
    assert_equal 250.0, positive_skew.fetch("scheduled_delay_ms")
    assert_equal "host_monotonic_same_boot", positive_skew.fetch("timing_authority")
  end

  test "returns unavailable when enqueue and worker are not in the same monotonic clock domain" do
    context = {
      "version" => 1,
      "clock_domain_id" => "boot-a",
      "enqueued_monotonic_seconds" => 100.0,
      "scheduled_delay_ms" => 0.0
    }

    measurement = RunDiff::Rails::QueueTimingContext.measure(
      context,
      clock_domain_id: "boot-b",
      monotonic_now: 100.13
    )

    assert_nil measurement
  end

  test "returns unavailable when the monotonic clock appears to move backwards" do
    context = {
      "version" => 1,
      "clock_domain_id" => "boot-a",
      "enqueued_monotonic_seconds" => 100.0,
      "scheduled_delay_ms" => 0.0
    }

    measurement = RunDiff::Rails::QueueTimingContext.measure(
      context,
      clock_domain_id: "boot-a",
      monotonic_now: 99.0
    )

    assert_nil measurement
  end
end
