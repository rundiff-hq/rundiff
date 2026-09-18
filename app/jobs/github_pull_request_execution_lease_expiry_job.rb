class GithubPullRequestExecutionLeaseExpiryJob < ApplicationJob
  queue_as :control

  LEASE_ERROR_CLASS = "RunDiff::Executor::LeaseExpired".freeze
  LEASE_FAILURE_PREFIX = "#{LEASE_ERROR_CLASS}:".freeze

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(execution_record_id, expired_at)
    execution = RunDiffExecution.find(execution_record_id)

    if RunDiffExecution::LEASED_STATUSES.include?(execution.status)
      return unless execution.expire_lease!(now: expired_at)
    elsif !lease_failure?(execution)
      return
    end

    token = installation_token(execution:)
    pull_request = current_pull_request(execution:, token: token.value)
    if (reason = stale_reason(execution:, pull_request:))
      execution.ignore!("#{reason}_after_lease_expiry")
      return
    end

    publication = execution_publisher(token: token.value).infra_failure(
      execution:,
      error_class: LEASE_ERROR_CLASS
    )

    Rails.logger.info(
      "RunDiff GitHub execution lease expired execution_id=#{execution.execution_id.inspect} " \
      "attempt=#{execution.attempt_count.inspect} check=#{publication.fetch(:check).inspect} " \
      "comment=#{publication.fetch(:comment).inspect}"
    )
  end

  private

  def lease_failure?(execution)
    execution.status == "failed" &&
      execution.outcome == "infra_failure" &&
      execution.failure.to_s.start_with?(LEASE_FAILURE_PREFIX)
  end

  def installation_token(execution:)
    app_authentication.installation_token(
      installation_id: Integer(execution.context.fetch("installation_id"))
    )
  end

  def current_pull_request(execution:, token:)
    pull_request_client(token:).fetch(
      repository: execution.context.fetch("repository"),
      number: Integer(execution.context.fetch("pull_request_number"))
    )
  end

  def stale_reason(execution:, pull_request:)
    return "stale_head" if pull_request.dig("head", "sha") != execution.candidate_sha
    return "stale_baseline" if pull_request.dig("base", "sha") != execution.baseline_sha

    nil
  end

  def app_authentication
    RunDiff::Github::AppAuthentication.from_env(root: ::Rails.root)
  end

  def pull_request_client(token:)
    RunDiff::Github::PullRequestClient.new(token:)
  end

  def execution_publisher(token:)
    RunDiff::Github::PullRequestExecutionPublisher.new(token:)
  end
end
