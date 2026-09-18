require "test_helper"

class RunDiffExecutorJobTest < ActiveJob::TestCase
  class TestJob < RunDiffExecutorJob
    attr_accessor :executor_override, :finalizer_override

    private

    def executor
      executor_override
    end

    def finalizer_job_class
      finalizer_override
    end
  end

  test "reconstructs the portable request and forwards a successful result" do
    executor = counting_executor(RunDiff::Executor::Result.success(payload))
    finalizer = counting_finalizer

    perform_job(executor:, finalizer:)

    request = executor.requests.first
    execution_id, result_payload = finalizer.calls.first
    result = RunDiff::Executor::Result.from_h(result_payload)

    assert_equal "github-123", request.execution_id
    assert_equal 2, request.attempt_number
    assert_equal "github-123", execution_id
    assert result.success?
    assert_equal payload, result.payload
  end

  test "preserves a portable executor failure result" do
    failure = RunDiff::Executor::Result.new(
      schema_version: "1",
      status: "failed",
      payload: nil,
      error_class: "RemoteWorker::CheckoutError",
      error_message: "repository unavailable"
    )
    finalizer = counting_finalizer

    perform_job(executor: counting_executor(failure), finalizer:)

    _execution_id, result_payload = finalizer.calls.first
    result = RunDiff::Executor::Result.from_h(result_payload)

    assert result.failure?
    assert_equal "RemoteWorker::CheckoutError", result.error_class
    assert_equal "repository unavailable", result.error_message
  end

  test "converts adapter exceptions into a portable failure result" do
    finalizer = counting_finalizer

    perform_job(
      executor: failing_executor(RuntimeError.new("transport unavailable")),
      finalizer:
    )

    execution_id, result_payload = finalizer.calls.first
    result = RunDiff::Executor::Result.from_h(result_payload)

    assert_equal "github-123", execution_id
    assert result.failure?
    assert_equal "RuntimeError", result.error_class
    assert_equal "transport unavailable", result.error_message
  end

  test "fails closed when an adapter returns an unversioned payload" do
    finalizer = counting_finalizer

    perform_job(executor: counting_executor(payload), finalizer:)

    _execution_id, result_payload = finalizer.calls.first
    result = RunDiff::Executor::Result.from_h(result_payload)

    assert result.failure?
    assert_equal "TypeError", result.error_class
    assert_equal "Executor adapter must return RunDiff::Executor::Result", result.error_message
  end

  private

  def perform_job(executor:, finalizer:)
    job = TestJob.new
    job.executor_override = executor
    job.finalizer_override = finalizer
    job.perform(request_payload)
  end

  def request_payload
    {
      "schema_version" => "1",
      "execution_id" => "github-123",
      "scenario_id" => "scenario",
      "baseline_sha" => "base",
      "candidate_sha" => "head",
      "attempt_number" => 2,
      "context" => {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 36,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    }
  end

  def payload
    { "run_id" => "run", "result" => { "decision" => "allow" } }
  end

  def counting_executor(result)
    Struct.new(:result, :requests) do
      def call(request:)
        requests << request
        result
      end
    end.new(result, [])
  end

  def failing_executor(error)
    Object.new.tap do |executor|
      executor.define_singleton_method(:call) do |request:|
        raise "missing request" unless request

        raise error
      end
    end
  end

  def counting_finalizer
    Struct.new(:calls) do
      def perform_later(execution_id, result_payload)
        calls << [ execution_id, result_payload ]
      end
    end.new([])
  end
end
