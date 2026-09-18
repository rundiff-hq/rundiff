class GithubCheckRunRerequestJob < ApplicationJob
  queue_as :control

  def perform(delivery_record_id)
    delivery = GithubWebhookDelivery.find(delivery_record_id)
    return unless delivery.event == "check_run" && delivery.action == "rerequested"
    return unless delivery.claim!

    execution = RunDiffExecution.find_by(execution_id: delivery.external_id)
    unless execution
      delivery.ignore!("execution_not_found")
      return
    end

    unless execution.rerunnable?
      delivery.ignore!("execution_not_rerunnable")
      return
    end

    token = app_authentication.installation_token(
      installation_id: delivery.installation_id || Integer(execution.context.fetch("installation_id"))
    )
    pull_request = pull_request_client(token: token.value).fetch(
      repository: execution.context.fetch("repository"),
      number: Integer(execution.context.fetch("pull_request_number"))
    )

    if stale_execution?(execution:, pull_request:)
      delivery.ignore!("stale_check_run")
      return
    end

    unless execution.requeue!
      delivery.ignore!("execution_not_rerunnable")
      return
    end

    execution_job_class.perform_later(execution.id)
    delivery.complete!

    Rails.logger.info(
      "RunDiff GitHub execution rerequested delivery=#{delivery.delivery_id.inspect} " \
      "execution_id=#{execution.execution_id.inspect} next_attempt=#{execution.attempt_count + 1}"
    )
  rescue StandardError => error
    delivery&.fail!(error)
    raise
  end

  private

  def stale_execution?(execution:, pull_request:)
    pull_request.dig("head", "sha") != execution.candidate_sha ||
      pull_request.dig("base", "sha") != execution.baseline_sha
  end

  def app_authentication
    RunDiff::Github::AppAuthentication.from_env(root: ::Rails.root)
  end

  def pull_request_client(token:)
    RunDiff::Github::PullRequestClient.new(token:)
  end

  def execution_job_class
    GithubPullRequestExecutionJob
  end
end
