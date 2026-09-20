class RunDiffExecutorCancellationJob < ApplicationJob
  queue_as :control

  def perform(execution_id, attempt_number, reason = "cancelled")
    execution = RunDiffExecution.find_by(execution_id:)
    return unless execution
    return unless execution.status == "cancelled"
    return unless execution.attempt_count == Integer(attempt_number)
    return if execution.context["execution_orchestrator"] == "github_actions"

    executor.cancel(
      execution_id:,
      attempt_number:,
      reason:
    )
  rescue StandardError => error
    Rails.logger.warn(
      "RunDiff executor cancellation delivery failed execution_id=#{execution_id.inspect} " \
      "attempt=#{attempt_number.inspect} error=#{error.class}"
    )
  end

  private

  def executor
    RunDiff::Executor::Resolver.from_env(root: Rails.root)
  end
end
