class GithubPullRequestExecutionLeaseReaperJob < ApplicationJob
  queue_as :control

  def perform(now = Time.current)
    RunDiffExecution
      .where(source: "github_pull_request", status: RunDiffExecution::LEASED_STATUSES)
      .where("lease_expires_at <= ?", now)
      .find_each do |execution|
        expiry_job_class.perform_later(execution.id, now)
      end
  end

  private

  def expiry_job_class
    GithubPullRequestExecutionLeaseExpiryJob
  end
end
