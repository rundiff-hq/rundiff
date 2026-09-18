require "test_helper"

class RunDiffExecutorLocalAdapterTest < ActiveSupport::TestCase
  test "delegates the portable request and returns a successful portable result" do
    requests = []
    runner = Object.new
    runner.define_singleton_method(:call) do |execution:|
      requests << execution
      { "result" => { "decision" => "allow" } }
    end

    request = executor_request
    result = RunDiff::Executor::LocalAdapter.new(runner:).call(request:)

    assert_equal [ request ], requests
    assert result.success?
    assert_equal "allow", result.payload.dig("result", "decision")
  end

  test "converts local runner failures into a portable result" do
    runner = Object.new
    runner.define_singleton_method(:call) do |execution:|
      raise "missing execution" unless execution

      raise RuntimeError, "worker unavailable"
    end

    result = RunDiff::Executor::LocalAdapter.new(runner:).call(request: executor_request)

    assert result.failure?
    assert_equal "RuntimeError", result.error_class
    assert_equal "worker unavailable", result.error_message
  end

  private

  def executor_request
    RunDiff::Executor::Request.new(
      schema_version: "1",
      execution_id: "github-123",
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
      attempt_number: 1,
      context: {}
    )
  end
end
