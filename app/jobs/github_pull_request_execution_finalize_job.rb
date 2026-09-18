class GithubPullRequestExecutionFinalizeJob < ApplicationJob
  queue_as :control

  def perform(execution_id, result_payload)
    RunDiff::ExecutionStageTimer.new.measure(
      execution_id:,
      stage: "finalization"
    ) do
      finalize(execution_id, result_payload)
    end
  end

  private

  def finalize(execution_id, result_payload)
    execution = RunDiffExecution.find_by!(execution_id:)
    unless execution.renew_lease!
      Rails.logger.info(
        "RunDiff GitHub executor result ignored execution_id=#{execution.execution_id.inspect} " \
        "reason=lease_expired_or_terminal"
      )
      return
    end

    result = RunDiff::Executor::Result.from_h(result_payload)
    token = installation_token(execution:)
    pull_request = current_pull_request(execution:, token: token.value)
    if (reason = stale_reason(execution:, pull_request:))
      ignore_stale!(execution:, reason: "#{reason}_before_finalize")
      return
    end

    unless execution.begin_finalization!(attempt_number: execution.attempt_count)
      Rails.logger.info(
        "RunDiff GitHub executor result ignored execution_id=#{execution.execution_id.inspect} " \
        "reason=cancelled_or_superseded_before_publish"
      )
      return
    end

    if result.failure?
      finalize_infra_failure(execution:, result:, token:)
      return
    end

    finalize_success(execution:, payload: result.payload, token:)
  rescue StandardError => error
    if execution&.fail!(error)
      publish_infra_failure(execution:, error:)
    end
    raise
  end

  def finalize_success(execution:, payload:, token:)
    publication = execution_publisher(token: token.value).call(execution:, payload:)
    if publication.fetch(:comment) == :stale
      execution.ignore!("stale_during_publish")
      return
    end

    return unless execution.complete!(payload)

    Rails.logger.info(
      "RunDiff GitHub execution finalized execution_id=#{execution.execution_id.inspect} " \
      "decision=#{execution.decision.inspect} outcome=#{execution.outcome.inspect} " \
      "attempt=#{execution.attempt_count.inspect} check=#{publication.fetch(:check).inspect} " \
      "comment=#{publication.fetch(:comment).inspect}"
    )
  end

  def finalize_infra_failure(execution:, result:, token:)
    return unless execution.fail_details!(error_class: result.error_class, error_message: result.error_message)

    publication = execution_publisher(token: token.value).infra_failure(
      execution:,
      error_class: result.error_class
    )

    Rails.logger.info(
      "RunDiff GitHub execution infra failure finalized execution_id=#{execution.execution_id.inspect} " \
      "attempt=#{execution.attempt_count.inspect} error_class=#{result.error_class.inspect} " \
      "check=#{publication.fetch(:check).inspect} comment=#{publication.fetch(:comment).inspect}"
    )
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

  def ignore_stale!(execution:, reason:)
    execution.ignore!(reason)
    Rails.logger.info(
      "RunDiff GitHub execution ignored execution_id=#{execution.execution_id.inspect} reason=#{reason.inspect}"
    )
  end

  def publish_infra_failure(execution:, error:)
    token = installation_token(execution:)
    pull_request = current_pull_request(execution:, token: token.value)
    return if stale_reason(execution:, pull_request:)

    execution_publisher(token: token.value).infra_failure(execution:, error:)
  rescue StandardError => publication_error
    Rails.logger.error(
      "RunDiff GitHub infra failure publication failed execution_id=#{execution.execution_id.inspect} " \
      "error=#{publication_error.class}"
    )
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
