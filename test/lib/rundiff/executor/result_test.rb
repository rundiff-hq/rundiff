require "test_helper"

class RunDiffExecutorResultTest < ActiveSupport::TestCase
  test "round-trips a successful result" do
    result = RunDiff::Executor::Result.success(
      "run_id" => "run-1",
      "result" => { "decision" => "allow" }
    )

    round_trip = RunDiff::Executor::Result.from_h(result.to_h)

    assert result.success?
    refute result.failure?
    assert_equal result, round_trip
    assert_nil result.error_class
  end

  test "serializes an executor failure without an exception object" do
    result = RunDiff::Executor::Result.failure(RuntimeError.new("worker unavailable"))
    round_trip = RunDiff::Executor::Result.from_h(result.to_h)

    assert result.failure?
    refute result.success?
    assert_equal "RuntimeError", round_trip.error_class
    assert_equal "worker unavailable", round_trip.error_message
    assert_nil round_trip.payload
  end

  test "rejects unknown schemas and statuses" do
    assert_raises(ArgumentError) do
      RunDiff::Executor::Result.from_h(
        "schema_version" => "2",
        "status" => "succeeded",
        "payload" => {}
      )
    end

    assert_raises(ArgumentError) do
      RunDiff::Executor::Result.from_h(
        "schema_version" => "1",
        "status" => "lost",
        "payload" => {}
      )
    end
  end
end
