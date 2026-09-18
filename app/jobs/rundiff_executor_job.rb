class RunDiffExecutorJob < ApplicationJob
  queue_as :default

  def perform(request_payload)
    execution_id = request_payload.fetch("execution_id")
    request = RunDiff::Executor::Request.from_h(request_payload)
    result = execute(request:)

    finalizer_job_class.perform_later(execution_id, result.to_h)
  end

  private

  def execute(request:)
    result = executor.call(request:)
    return result if result.is_a?(RunDiff::Executor::Result)

    raise TypeError, "Executor adapter must return RunDiff::Executor::Result"
  rescue StandardError => error
    RunDiff::Executor::Result.failure(error)
  end

  def executor
    RunDiff::Executor::Resolver.from_env(root: Rails.root)
  end

  def finalizer_job_class
    GithubPullRequestExecutionFinalizeJob
  end
end
