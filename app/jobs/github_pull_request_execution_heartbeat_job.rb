class GithubPullRequestExecutionHeartbeatJob < ApplicationJob
  queue_as :control

  def self.schedule(execution_id, attempt_number)
    set(wait: interval_seconds.seconds).perform_later(execution_id, attempt_number)
  end

  def self.interval_seconds
    default = [ RunDiffExecution.lease_seconds / 3, 1 ].max
    interval = Integer(ENV.fetch("RUNDIFF_EXECUTION_HEARTBEAT_INTERVAL_SECONDS", default))
    raise ArgumentError, "Execution heartbeat interval must be positive" unless interval.positive?
    if interval >= RunDiffExecution.lease_seconds
      raise ArgumentError, "Execution heartbeat interval must be shorter than the execution lease"
    end

    interval
  end

  def perform(execution_id, attempt_number)
    execution = RunDiffExecution.find_by(execution_id:)
    return unless execution
    return unless RunDiffExecution::LEASED_STATUSES.include?(execution.status)
    return unless execution.attempt_count == Integer(attempt_number)
    return unless execution.renew_lease!

    self.class.schedule(execution.execution_id, execution.attempt_count)
  end
end
