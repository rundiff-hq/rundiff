require "test_helper"

class ExecutorExecutionsControllerTest < ActionDispatch::IntegrationTest
  test "returns a durable completed executor result to an authenticated caller" do
    with_executor_service_env do
      result = RunDiff::Executor::Result.success(result_payload)
      acquisition = RunDiffExecutorRequest.acquire!(
        idempotency_key: "github-123:1",
        request_payload: request_payload,
        lease_seconds: 60
      )
      acquisition.record.complete_claim!(
        claim_token: acquisition.claim_token,
        result_payload: result.to_h
      )

      post_executor(request_payload, idempotency_key: "github-123:1")

      assert_response :ok
      assert_equal result.to_h, response.parsed_body
    end
  end

  test "requires the executor service bearer token" do
    with_executor_service_env do
      post executor_service_executions_url,
        params: JSON.generate(request_payload),
        headers: {
          "CONTENT_TYPE" => "application/json",
          "Authorization" => "Bearer wrong-token",
          "Idempotency-Key" => "github-123:1"
        }

      assert_response :unauthorized
      assert_equal "Unauthorized", response.parsed_body.fetch("error")
    end
  end

  test "requires an idempotency key" do
    with_executor_service_env do
      post executor_service_executions_url,
        params: JSON.generate(request_payload),
        headers: authenticated_headers

      assert_response :bad_request
      assert_equal "Idempotency-Key is required", response.parsed_body.fetch("error")
    end
  end

  test "rejects an invalid portable request" do
    with_executor_service_env do
      invalid = request_payload.except("candidate_sha")
      post_executor(invalid, idempotency_key: "github-123:1")

      assert_response :unprocessable_entity
      assert_match(/candidate_sha/, response.parsed_body.fetch("error"))
    end
  end

  test "returns conflict while an identical request is already processing" do
    with_executor_service_env do
      RunDiffExecutorRequest.acquire!(
        idempotency_key: "github-123:1",
        request_payload: request_payload,
        lease_seconds: 60
      )

      post_executor(request_payload, idempotency_key: "github-123:1")

      assert_response :conflict
      assert_equal "5", response.headers.fetch("Retry-After")
      assert_equal "Executor request is already processing", response.parsed_body.fetch("error")
    end
  end

  test "accepts cancellation before request arrival and rejects later execution" do
    with_executor_service_env do
      post_cancel(reason: "superseded")

      assert_response :accepted
      assert_equal "cancelled", response.parsed_body.fetch("status")
      record = RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1")
      assert_equal "cancelled", record.status
      assert_equal "superseded", record.cancellation_reason

      post_executor(request_payload, idempotency_key: "github-123:1")

      assert_response :conflict
      assert_equal "Executor request was cancelled", response.parsed_body.fetch("error")
    end
  end

  test "accepts cancellation even when the worker adapter is disabled" do
    with_executor_service_env do
      ENV["RUNDIFF_EXECUTOR_SERVICE_ADAPTER"] = "disabled"

      post_cancel(reason: "shutdown")

      assert_response :accepted
      record = RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1")
      assert_equal "cancelled", record.status
      assert_equal "shutdown", record.cancellation_reason
    end
  end

  test "cancellation is idempotent but cannot replace a completed result" do
    with_executor_service_env do
      post_cancel(reason: "first")
      assert_response :accepted
      post_cancel(reason: "second")
      assert_response :accepted

      RunDiffExecutorRequest.delete_all
      result = RunDiff::Executor::Result.success(result_payload)
      acquisition = RunDiffExecutorRequest.acquire!(
        idempotency_key: "github-123:1",
        request_payload: request_payload,
        lease_seconds: 60
      )
      acquisition.record.complete_claim!(
        claim_token: acquisition.claim_token,
        result_payload: result.to_h
      )

      post_cancel(reason: "too-late")

      assert_response :conflict
      assert_equal "Executor request already completed", response.parsed_body.fetch("error")
    end
  end

  private

  def with_executor_service_env
    previous_token = ENV["RUNDIFF_EXECUTOR_SERVICE_TOKEN"]
    previous_adapter = ENV["RUNDIFF_EXECUTOR_SERVICE_ADAPTER"]
    previous_lease = ENV["RUNDIFF_EXECUTOR_SERVICE_REQUEST_LEASE_SECONDS"]

    ENV["RUNDIFF_EXECUTOR_SERVICE_TOKEN"] = "executor-secret"
    ENV["RUNDIFF_EXECUTOR_SERVICE_ADAPTER"] = "local"
    ENV["RUNDIFF_EXECUTOR_SERVICE_REQUEST_LEASE_SECONDS"] = "60"
    yield
  ensure
    ENV["RUNDIFF_EXECUTOR_SERVICE_TOKEN"] = previous_token
    ENV["RUNDIFF_EXECUTOR_SERVICE_ADAPTER"] = previous_adapter
    ENV["RUNDIFF_EXECUTOR_SERVICE_REQUEST_LEASE_SECONDS"] = previous_lease
  end

  def post_executor(payload, idempotency_key:)
    post executor_service_executions_url,
      params: JSON.generate(payload),
      headers: authenticated_headers.merge("Idempotency-Key" => idempotency_key)
  end

  def post_cancel(reason:)
    post cancel_executor_service_execution_url(execution_id: "github-123", attempt_number: 1),
      params: JSON.generate("reason" => reason),
      headers: authenticated_headers
  end

  def authenticated_headers
    {
      "CONTENT_TYPE" => "application/json",
      "Authorization" => "Bearer executor-secret"
    }
  end

  def request_payload
    {
      "schema_version" => "1",
      "execution_id" => "github-123",
      "scenario_id" => "scenario",
      "baseline_sha" => "base",
      "candidate_sha" => "head",
      "attempt_number" => 1,
      "context" => {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 40,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    }
  end

  def result_payload
    { "run_id" => "run", "result" => { "decision" => "allow" } }
  end
end
