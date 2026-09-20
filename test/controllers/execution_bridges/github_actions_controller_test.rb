require "test_helper"

class ExecutionBridgesGithubActionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "claims the exact live execution as a portable request" do
    with_bridge_token do
      execution = create_running_execution

      post github_actions_execution_bridge_claim_url,
        params: JSON.generate(claim_payload),
        headers: authenticated_headers

      assert_response :ok
      request_payload = response.parsed_body.fetch("request")
      request_contract = RunDiff::Executor::Request.from_h(request_payload)
      assert_equal execution.execution_id, request_contract.execution_id
      assert_equal execution.attempt_count, request_contract.attempt_number
      refute_includes request_contract.context, "installation_id"
    end
  end

  test "claim returns retryable conflict until matching execution is ready" do
    with_bridge_token do
      post github_actions_execution_bridge_claim_url,
        params: JSON.generate(claim_payload),
        headers: authenticated_headers

      assert_response :conflict
      assert_equal "3", response.headers.fetch("Retry-After")
      assert_equal "Matching RunDiff execution is not ready", response.parsed_body.fetch("error")
    end
  end

  test "requires bridge bearer token" do
    with_bridge_token do
      post github_actions_execution_bridge_claim_url,
        params: JSON.generate(claim_payload),
        headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer wrong" }

      assert_response :unauthorized
    end
  end

  test "accepts a portable result for the exact live attempt" do
    with_bridge_token do
      execution = create_running_execution
      result = RunDiff::Executor::Result.success(
        "run_id" => "run-1",
        "result" => { "decision" => "allow" }
      )

      assert_enqueued_with(
        job: GithubPullRequestExecutionFinalizeJob,
        args: [execution.execution_id, result.to_h]
      ) do
        post github_actions_execution_bridge_result_url(
          execution_id: execution.execution_id,
          attempt_number: execution.attempt_count
        ),
          params: JSON.generate(result.to_h),
          headers: authenticated_headers
      end

      assert_response :accepted
      assert_equal "accepted", response.parsed_body.fetch("status")
    end
  end

  test "rejects a stale attempt result" do
    with_bridge_token do
      execution = create_running_execution
      result = RunDiff::Executor::Result.success(
        "run_id" => "run-1",
        "result" => { "decision" => "allow" }
      )

      post github_actions_execution_bridge_result_url(
        execution_id: execution.execution_id,
        attempt_number: execution.attempt_count + 1
      ),
        params: JSON.generate(result.to_h),
        headers: authenticated_headers

      assert_response :conflict
      assert_match(/attempt does not match/, response.parsed_body.fetch("error"))
    end
  end

  private

  def with_bridge_token
    previous = ENV["RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN"]
    ENV["RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN"] = "bridge-secret"
    yield
  ensure
    ENV["RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN"] = previous
  end

  def authenticated_headers
    {
      "CONTENT_TYPE" => "application/json",
      "Authorization" => "Bearer bridge-secret"
    }
  end

  def claim_payload
    {
      "repository" => "acme/app",
      "pull_request_number" => 42,
      "baseline_sha" => "base-sha",
      "candidate_sha" => "head-sha"
    }
  end

  def create_running_execution
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(32)}",
      source: "github_pull_request",
      scenario_id: "dogfood.git.behavior",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      context: {
        "repository" => "acme/app",
        "pull_request_number" => 42,
        "installation_id" => 123,
        "delivery_id" => "delivery",
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "acme/app"
      }
    )
    assert execution.claim!
    execution
  end
end
