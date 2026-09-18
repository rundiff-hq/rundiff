require "test_helper"

class RunDiffExecutorCancellationJobTest < ActiveJob::TestCase
  class TestJob < RunDiffExecutorCancellationJob
    attr_accessor :executor_override

    private

    def executor
      executor_override
    end
  end

  test "delivers cancellation for the exact cancelled attempt" do
    execution = cancelled_execution
    executor = recording_executor
    job = TestJob.new
    job.executor_override = executor

    job.perform(execution.execution_id, 1, "superseded")

    assert_equal [ [ execution.execution_id, 1, "superseded" ] ], executor.calls
    assert_equal "cancelled", execution.reload.status
    assert_equal "cancelled", execution.outcome
  end

  test "does not deliver cancellation for a superseded attempt" do
    execution = cancelled_execution
    execution.update!(attempt_count: 2)
    executor = recording_executor
    job = TestJob.new
    job.executor_override = executor

    job.perform(execution.execution_id, 1, "old-attempt")

    assert_empty executor.calls
  end

  test "delivery failure never changes cancellation into infrastructure failure" do
    execution = cancelled_execution
    executor = Object.new
    executor.define_singleton_method(:cancel) do |**|
      raise RuntimeError, "executor unreachable"
    end
    job = TestJob.new
    job.executor_override = executor

    assert_nothing_raised do
      job.perform(execution.execution_id, 1, "user_cancelled")
    end

    execution.reload
    assert_equal "cancelled", execution.status
    assert_equal "cancelled", execution.outcome
    assert_nil execution.failure
    refute execution.rerunnable?
  end

  private

  def cancelled_execution
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(16)}",
      source: "github_pull_request",
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
      context: {}
    )
    execution.claim!
    execution.cancel!(attempt_number: 1, reason: "user_cancelled")
    execution
  end

  def recording_executor
    Struct.new(:calls) do
      def cancel(execution_id:, attempt_number:, reason:)
        calls << [ execution_id, attempt_number, reason ]
        true
      end
    end.new([])
  end
end
