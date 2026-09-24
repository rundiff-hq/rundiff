module ExecutionBridges
  class GithubActionsController < ApplicationController
    skip_forgery_protection
    before_action :authenticate_bridge!

    def claim
      payload = json_payload
      request_contract = bridge.claim(
        repository: payload.fetch("repository"),
        pull_request_number: payload.fetch("pull_request_number"),
        baseline_sha: payload.fetch("baseline_sha"),
        candidate_sha: payload.fetch("candidate_sha")
      )

      render json: { "request" => request_contract.to_h }, status: :ok
    rescue RunDiff::Execution::GithubActionsBridge::ClaimNotReady => error
      response.set_header("Retry-After", "3")
      render_error(error.message, status: :conflict)
    rescue KeyError, ArgumentError => error
      render_error(error.message, status: :unprocessable_entity)
    rescue JSON::ParserError => error
      render_error("Invalid JSON: #{error.message}", status: :bad_request)
    end

    def result
      payload = json_payload
      bridge.submit_result(
        execution_id: params.fetch(:execution_id),
        attempt_number: params.fetch(:attempt_number),
        result_payload: payload
      )

      render json: { "status" => "accepted" }, status: :accepted
    rescue RunDiff::Execution::GithubActionsBridge::InvalidAttempt => error
      render_error(error.message, status: :conflict)
    rescue KeyError, ArgumentError => error
      render_error(error.message, status: :unprocessable_entity)
    rescue JSON::ParserError => error
      render_error("Invalid JSON: #{error.message}", status: :bad_request)
    end

    private

    def bridge
      RunDiff::Execution::GithubActionsBridge.new
    end

    def json_payload
      payload = JSON.parse(request.raw_post)
      raise ArgumentError, "Request body must be a JSON object" unless payload.is_a?(Hash)

      payload
    end

    def authenticate_bridge!
      token = ENV["RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN"].to_s
      if token.empty?
        render_error("GitHub Actions bridge token is not configured", status: :service_unavailable)
        return
      end

      expected = "Bearer #{token}"
      provided = request.authorization.to_s
      authenticated = provided.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(provided, expected)

      render_error("Unauthorized", status: :unauthorized) unless authenticated
    end

    def render_error(message, status:)
      render json: { "error" => message }, status:
    end
  end
end
