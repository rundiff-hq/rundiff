require "test_helper"

class RunDiffExecutionOrchestratorDispatchTest < ActiveSupport::TestCase
  test "native orchestrator enqueues the existing executor job" do
    job = counting_job
    dispatcher = RunDiff::Execution::OrchestratorDispatch.new(
      mode: "native",
      executor_job: job
    )

    mode = dispatcher.call(request: request)

    assert_equal "native", mode
    assert_equal [request.to_h], job.payloads
  end

  test "github actions orchestrator leaves execution for external claim" do
    job = counting_job
    dispatcher = RunDiff::Execution::OrchestratorDispatch.new(
      mode: "github_actions",
      executor_job: job
    )

    mode = dispatcher.call(request: request)

    assert_equal "github_actions", mode
    assert_empty job.payloads
  end

  test "rejects unsupported orchestrator" do
    error = assert_raises(RunDiff::Execution::OrchestratorDispatch::Error) do
      RunDiff::Execution::OrchestratorDispatch.new(mode: "magic")
    end

    assert_match(/Unsupported RUNDIFF_EXECUTION_ORCHESTRATOR/, error.message)
  end

  private

  def counting_job
    Struct.new(:payloads) do
      def perform_later(payload)
        payloads << payload
      end
    end.new([])
  end

  def request
    @request ||= RunDiff::Executor::Request.from_h(
      "schema_version" => "1",
      "execution_id" => "github-123",
      "scenario_id" => "scenario",
      "baseline_sha" => "base",
      "candidate_sha" => "head",
      "attempt_number" => 1,
      "context" => {
        "repository" => "acme/app",
        "pull_request_number" => 42,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "acme/app"
      }
    )
  end
end
