require "test_helper"

class RunDiffExecutorServiceTest < ActiveSupport::TestCase
  test "executes once and replays the durable result for an identical idempotency key" do
    adapter = counting_adapter(RunDiff::Executor::Result.success(result_payload))
    service = service(adapter:)

    first = service.call(idempotency_key: "github-123:1", request_payload: request_payload)
    second = service.call(idempotency_key: "github-123:1", request_payload: request_payload)

    assert first.success?
    assert second.success?
    assert_equal result_payload, second.payload
    assert_equal 1, adapter.calls
    assert_equal "completed", RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1").status
  end

  test "passes repository capability to the worker without persisting it" do
    capability = RunDiff::Executor::RepositoryCapability.new(token: "clone-token")
    adapter = recording_adapter(RunDiff::Executor::Result.success(result_payload))

    result = service(adapter:).call(
      idempotency_key: "github-123:1",
      request_payload: request_payload,
      repository_capability: capability
    )

    assert result.success?
    assert_same capability, adapter.capabilities.fetch(0)

    record = RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1")
    refute_includes JSON.generate(record.request_payload), "clone-token"
    refute_includes JSON.generate(record.result), "clone-token"
  end

  test "preserves a worker failure as a durable portable result" do
    failure = RunDiff::Executor::Result.new(
      schema_version: "1",
      status: "failed",
      payload: nil,
      error_class: "RemoteWorker::CheckoutError",
      error_message: "repository unavailable"
    )
    service = service(adapter: counting_adapter(failure))

    result = service.call(idempotency_key: "github-123:1", request_payload: request_payload)

    assert result.failure?
    assert_equal "RemoteWorker::CheckoutError", result.error_class
    assert_equal failure.to_h, RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1").result
  end

  test "converts an adapter exception into a durable failed result" do
    adapter = Object.new
    adapter.define_singleton_method(:call) do |request:, repository_capability: nil|
      raise "missing request" unless request
      raise "unexpected capability" if repository_capability

      raise RuntimeError, "worker crashed"
    end

    result = service(adapter:).call(
      idempotency_key: "github-123:1",
      request_payload: request_payload
    )

    assert result.failure?
    assert_equal "RuntimeError", result.error_class
    assert_equal "worker crashed", result.error_message
    assert_equal result.to_h, RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1").result
  end

  test "fails closed when the worker adapter returns an unversioned payload" do
    service = service(adapter: counting_adapter(result_payload))

    result = service.call(idempotency_key: "github-123:1", request_payload: request_payload)

    assert result.failure?
    assert_equal "TypeError", result.error_class
    assert_equal "Executor service adapter must return RunDiff::Executor::Result", result.error_message
  end

  test "rejects a duplicate request while the first claim is still live" do
    RunDiffExecutorRequest.acquire!(
      idempotency_key: "github-123:1",
      request_payload: request_payload,
      lease_seconds: 60
    )

    error = assert_raises(RunDiff::Executor::Service::RequestInProgress) do
      service(adapter: counting_adapter(RunDiff::Executor::Result.success(result_payload))).call(
        idempotency_key: "github-123:1",
        request_payload: request_payload
      )
    end

    assert_equal "Executor request is already processing", error.message
  end

  test "rejects idempotency key reuse for a different request" do
    adapter = counting_adapter(RunDiff::Executor::Result.success(result_payload))
    service = service(adapter:)
    service.call(idempotency_key: "github-123:1", request_payload: request_payload)

    changed = request_payload.merge("candidate_sha" => "different-head")
    assert_raises(RunDiff::Executor::Service::RequestConflict) do
      service.call(idempotency_key: "github-123:1", request_payload: changed)
    end
  end

  test "cancellation before request arrival prevents worker execution" do
    adapter = counting_adapter(RunDiff::Executor::Result.success(result_payload))
    service = service(adapter:)

    cancellation = service.cancel(idempotency_key: "github-123:1", reason: "superseded")

    assert_equal :cancelled, cancellation.state
    error = assert_raises(RunDiff::Executor::Service::RequestCancelled) do
      service.call(idempotency_key: "github-123:1", request_payload: request_payload)
    end
    assert_equal "Executor request was cancelled", error.message
    assert_equal 0, adapter.calls
  end

  test "cancellation during worker execution rejects the late result" do
    adapter = Object.new
    adapter.define_singleton_method(:call) do |request:, repository_capability: nil|
      raise "unexpected capability" if repository_capability

      RunDiffExecutorRequest.cancel!(
        idempotency_key: "#{request.execution_id}:#{request.attempt_number}",
        reason: "control_plane_cancelled"
      )
      RunDiff::Executor::Result.success({ "late" => true })
    end

    error = assert_raises(RunDiff::Executor::Service::RequestCancelled) do
      service(adapter:).call(idempotency_key: "github-123:1", request_payload: request_payload)
    end

    assert_equal "Executor request was cancelled", error.message
    record = RunDiffExecutorRequest.find_by!(idempotency_key: "github-123:1")
    assert_equal "cancelled", record.status
    assert_equal({}, record.result)
  end

  private

  def service(adapter:)
    RunDiff::Executor::Service.new(adapter:, lease_seconds: 60)
  end

  def counting_adapter(result)
    Struct.new(:result, :calls) do
      def call(request:, repository_capability: nil)
        raise "missing request" unless request
        raise "unexpected capability" if repository_capability

        self.calls += 1
        result
      end
    end.new(result, 0)
  end

  def recording_adapter(result)
    Struct.new(:result, :capabilities) do
      def call(request:, repository_capability: nil)
        raise "missing request" unless request

        capabilities << repository_capability
        result
      end
    end.new(result, [])
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
