require "test_helper"

class RunDiffExecutorRequestTest < ActiveSupport::TestCase
  test "serializes only executor-safe execution context" do
    execution = RunDiffExecution.new(
      execution_id: "github-123",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      attempt_count: 2,
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 36,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff",
        "installation_id" => 123,
        "delivery_id" => "delivery-secret-boundary"
      }
    )

    request = RunDiff::Executor::Request.from_execution(execution)
    round_trip = RunDiff::Executor::Request.from_h(request.to_h)

    assert_equal "1", request.schema_version
    assert_equal "github-123", request.execution_id
    assert_equal 2, request.attempt_number
    assert_equal request, round_trip
    assert_equal %w[baseline_ref candidate_ref candidate_repository pull_request_number repository].sort,
      request.context.keys.sort
    refute_includes request.context, "installation_id"
    refute_includes request.context, "delivery_id"
  end

  test "rejects an unknown schema version" do
    error = assert_raises(ArgumentError) do
      RunDiff::Executor::Request.from_h(
        "schema_version" => "2",
        "execution_id" => "github-123",
        "scenario_id" => "scenario",
        "baseline_sha" => "base",
        "candidate_sha" => "head",
        "attempt_number" => 1,
        "context" => {}
      )
    end

    assert_match(/Unsupported executor request schema/, error.message)
  end
end
