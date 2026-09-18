require "test_helper"

class RunDiffExecutorHttpAdapterTest < ActiveSupport::TestCase
  test "posts a versioned request and returns the portable result" do
    transport = recording_transport(
      status: 200,
      body: JSON.generate(RunDiff::Executor::Result.success(payload).to_h)
    )
    adapter = adapter(transport:)

    result = adapter.call(request: executor_request)

    assert_equal 1, transport.calls.length
    call = transport.calls.first
    assert_equal "https", call.fetch(:uri).scheme
    assert_equal "executor.example.test", call.fetch(:uri).host
    assert_equal "/v1/executions", call.fetch(:uri).path
    assert_equal "Bearer remote-secret", call.fetch(:headers).fetch("Authorization")
    assert_equal "github-123:2", call.fetch(:headers).fetch("Idempotency-Key")
    assert_equal executor_request.to_h, JSON.parse(call.fetch(:body))
    assert_equal 3, call.fetch(:open_timeout)
    assert_equal 120, call.fetch(:read_timeout)
    assert result.success?
    assert_equal payload, result.payload
  end

  test "sends a repository capability only as an HTTP header" do
    transport = recording_transport(
      status: 200,
      body: JSON.generate(RunDiff::Executor::Result.success(payload).to_h)
    )
    provider = Object.new
    provider.define_singleton_method(:call) do |request:|
      raise "unexpected request" unless request.execution_id == "github-123"

      RunDiff::Executor::RepositoryCapability.new(token: "clone-token")
    end

    adapter(transport:, repository_capability_provider: provider).call(request: executor_request)

    call = transport.calls.fetch(0)
    assert_equal(
      "Bearer clone-token",
      call.fetch(:headers).fetch(RunDiff::Executor::RepositoryCapability::HEADER)
    )
    refute_includes call.fetch(:body), "clone-token"
    assert_equal executor_request.to_h, JSON.parse(call.fetch(:body))
  end

  test "posts cancellation for the exact execution attempt with a bounded control timeout" do
    transport = recording_transport(status: 202, body: JSON.generate("status" => "cancelled"))

    result = adapter(transport:).cancel(
      execution_id: "github-123",
      attempt_number: 2,
      reason: "superseded"
    )

    assert result
    call = transport.calls.fetch(0)
    assert_equal "/v1/executions/github-123/attempts/2/cancel", call.fetch(:uri).path
    assert_equal "Bearer remote-secret", call.fetch(:headers).fetch("Authorization")
    refute_includes call.fetch(:headers), "Idempotency-Key"
    assert_equal({ "reason" => "superseded" }, JSON.parse(call.fetch(:body)))
    assert_equal 30, call.fetch(:read_timeout)
  end

  test "fails cancellation when the remote executor rejects it" do
    transport = recording_transport(status: 503, body: "unavailable")

    error = assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      adapter(transport:).cancel(execution_id: "github-123", attempt_number: 2)
    end

    assert_equal "Remote executor cancellation returned HTTP 503", error.message
  end

  test "preserves a remote worker failure result" do
    remote_failure = RunDiff::Executor::Result.new(
      schema_version: "1",
      status: "failed",
      payload: nil,
      error_class: "RemoteWorker::CheckoutError",
      error_message: "repository unavailable"
    )
    transport = recording_transport(status: 200, body: JSON.generate(remote_failure.to_h))

    result = adapter(transport:).call(request: executor_request)

    assert result.failure?
    assert_equal "RemoteWorker::CheckoutError", result.error_class
    assert_equal "repository unavailable", result.error_message
  end

  test "reports execution id and wait phase on remote read timeout" do
    transport = Struct.new(:calls) do
      def call(**arguments)
        calls << arguments
        raise Net::ReadTimeout.new("timed out")
      end
    end.new([])

    error = assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      adapter(transport:).call(request: executor_request)
    end

    assert_includes error.message, 'execution_id="github-123"'
    assert_includes error.message, "phase=remote_executor_wait"
    assert_includes error.message, "error_class=Net::ReadTimeout"
    refute_includes error.message, "remote-secret"
    refute_includes error.message, "clone-token"
  end

  test "reports execution id and connect phase on remote open timeout" do
    transport = Struct.new(:calls) do
      def call(**arguments)
        calls << arguments
        raise Net::OpenTimeout.new("timed out")
      end
    end.new([])

    error = assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      adapter(transport:).call(request: executor_request)
    end

    assert_includes error.message, 'execution_id="github-123"'
    assert_includes error.message, "phase=remote_executor_connect"
    assert_includes error.message, "error_class=Net::OpenTimeout"
    refute_includes error.message, "remote-secret"
  end

  test "fails on a non-success HTTP response" do
    transport = recording_transport(status: 503, body: "unavailable")

    error = assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      adapter(transport:).call(request: executor_request)
    end

    assert_equal "Remote executor returned HTTP 503", error.message
  end

  test "fails on malformed result JSON" do
    transport = recording_transport(status: 200, body: "not-json")

    error = assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      adapter(transport:).call(request: executor_request)
    end

    assert_match(/Remote executor returned invalid JSON/, error.message)
  end

  test "fails when the result is not a JSON object" do
    transport = recording_transport(status: 200, body: JSON.generate([]))

    error = assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      adapter(transport:).call(request: executor_request)
    end

    assert_equal "Remote executor result must be a JSON object", error.message
  end

  test "rejects insecure or incomplete configuration" do
    assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      RunDiff::Executor::HttpAdapter.new(url: "file:///tmp/executor", token: "secret")
    end

    assert_raises(RunDiff::Executor::HttpAdapter::Error) do
      RunDiff::Executor::HttpAdapter.new(url: "https://executor.example.test", token: "")
    end
  end

  private

  def adapter(transport:, repository_capability_provider: nil)
    RunDiff::Executor::HttpAdapter.new(
      url: "https://executor.example.test/v1/executions",
      token: "remote-secret",
      open_timeout: 3,
      read_timeout: 120,
      transport:,
      repository_capability_provider:
    )
  end

  def executor_request
    RunDiff::Executor::Request.new(
      schema_version: "1",
      execution_id: "github-123",
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
      attempt_number: 2,
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 39,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    )
  end

  def payload
    { "run_id" => "run", "result" => { "decision" => "allow" } }
  end

  def recording_transport(status:, body:)
    Struct.new(:response, :calls) do
      def call(**arguments)
        calls << arguments
        response
      end
    end.new(
      RunDiff::Executor::HttpAdapter::Response.new(status:, body:),
      []
    )
  end
end
