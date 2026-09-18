require "test_helper"

class RunDiffExecutorCancellationTest < ActiveSupport::TestCase
  test "marks the active attempt cancelled before scheduling remote notification" do
    execution = running_execution
    notification_job = recording_notification_job
    cancellation = RunDiff::Executor::Cancellation.new(notification_job:)

    assert cancellation.call(execution:, reason: "superseded")

    execution.reload
    assert_equal "cancelled", execution.status
    assert_equal "cancelled", execution.outcome
    assert_equal "superseded", execution.cancellation_reason
    assert_equal [ [ execution.execution_id, 1, "superseded" ] ], notification_job.calls
  end

  test "cancels queued work without notifying an executor that never received an attempt" do
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(16)}",
      source: "github_pull_request",
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
      context: {}
    )
    notification_job = recording_notification_job

    assert RunDiff::Executor::Cancellation.new(notification_job:).call(execution:, reason: "user_cancelled")

    assert_equal "cancelled", execution.reload.status
    assert_empty notification_job.calls
  end

  test "keeps durable cancellation when notification enqueue fails" do
    execution = running_execution
    notification_job = Object.new
    notification_job.define_singleton_method(:perform_later) do |*|
      raise RuntimeError, "queue unavailable"
    end

    assert RunDiff::Executor::Cancellation.new(notification_job:).call(execution:, reason: "user_cancelled")

    execution.reload
    assert_equal "cancelled", execution.status
    assert_equal "cancelled", execution.outcome
    assert_equal "user_cancelled", execution.cancellation_reason
    assert_nil execution.failure
  end

  private

  def running_execution
    execution = RunDiffExecution.create!(
      execution_id: "github-#{SecureRandom.hex(16)}",
      source: "github_pull_request",
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
      context: {}
    )
    execution.claim!
    execution
  end

  def recording_notification_job
    Struct.new(:calls) do
      def perform_later(*arguments)
        calls << arguments
      end
    end.new([])
  end
end
