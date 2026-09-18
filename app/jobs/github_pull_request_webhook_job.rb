class GithubPullRequestWebhookJob < ApplicationJob
  queue_as :control

  def perform(delivery_record_id)
    delivery = GithubWebhookDelivery.find(delivery_record_id)
    return unless delivery.pull_request?
    return unless delivery.claim!

    token = app_authentication.installation_token(installation_id: delivery.installation_id)
    pull_request = pull_request_client(token: token.value).fetch(
      repository: delivery.repository,
      number: delivery.pull_request_number
    )

    current_head_sha = pull_request.dig("head", "sha")
    if current_head_sha != delivery.head_sha
      delivery.ignore!("stale_head")
      Rails.logger.info(
        "RunDiff GitHub delivery ignored delivery=#{delivery.delivery_id.inspect} reason=stale_head " \
        "expected_head_sha=#{delivery.head_sha.inspect} current_head_sha=#{current_head_sha.inspect}"
      )
      return
    end

    unless delivery.runnable_pull_request?
      delivery.ignore!("action_not_execution_trigger")
      Rails.logger.info(
        "RunDiff GitHub App authenticated delivery=#{delivery.delivery_id.inspect} " \
        "repository=#{delivery.repository.inspect} pr=#{delivery.pull_request_number.inspect} " \
        "action=#{delivery.action.inspect} token_expires_at=#{token.expires_at.iso8601.inspect} execution=ignored"
      )
      return
    end

    execution, enqueue = execution_dispatcher.call(delivery:, pull_request:)
    execution_job_class.perform_later(execution.id) if enqueue

    delivery.complete!
    Rails.logger.info(
      "RunDiff GitHub App authenticated delivery=#{delivery.delivery_id.inspect} " \
      "repository=#{delivery.repository.inspect} pr=#{delivery.pull_request_number.inspect} " \
      "head_sha=#{delivery.head_sha.inspect} installation_id=#{delivery.installation_id.inspect} " \
      "token_expires_at=#{token.expires_at.iso8601.inspect} execution_id=#{execution.execution_id.inspect} " \
      "execution=#{enqueue ? "queued" : execution.status}"
    )
  rescue StandardError => error
    delivery&.fail!(error)
    raise
  end

  private

  def app_authentication
    RunDiff::Github::AppAuthentication.from_env(root: ::Rails.root)
  end

  def pull_request_client(token:)
    RunDiff::Github::PullRequestClient.new(token:)
  end

  def execution_dispatcher
    RunDiff::Github::ExecutionDispatcher.new
  end

  def execution_job_class
    GithubPullRequestExecutionJob
  end
end
