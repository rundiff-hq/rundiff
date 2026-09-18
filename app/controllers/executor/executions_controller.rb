module Executor
  class ExecutionsController < ApplicationController
    skip_forgery_protection
    before_action :authenticate_executor_service!

    def create
      idempotency_key = request.headers["Idempotency-Key"].to_s
      return render_error("Idempotency-Key is required", status: :bad_request) if idempotency_key.empty?

      payload = JSON.parse(request.raw_post)
      return render_error("Executor request must be a JSON object", status: :unprocessable_entity) unless payload.is_a?(Hash)

      repository_capability = RunDiff::Executor::RepositoryCapability.from_header(
        request.headers[RunDiff::Executor::RepositoryCapability::HEADER]
      )
      result = executor_service.call(
        idempotency_key:,
        request_payload: payload,
        repository_capability:
      )
      render json: result.to_h, status: :ok
    rescue JSON::ParserError => error
      render_error("Invalid JSON: #{error.message}", status: :bad_request)
    rescue KeyError, ArgumentError => error
      render_error(error.message, status: :unprocessable_entity)
    rescue RunDiff::Executor::Service::RequestConflict => error
      render_error(error.message, status: :conflict)
    rescue RunDiff::Executor::Service::RequestCancelled => error
      render_error(error.message, status: :conflict)
    rescue RunDiff::Executor::Service::RequestInProgress => error
      response.set_header("Retry-After", "5")
      render_error(error.message, status: :conflict)
    rescue RunDiff::Executor::Service::ClaimLost => error
      response.set_header("Retry-After", "5")
      render_error(error.message, status: :conflict)
    rescue RunDiff::Executor::ServiceResolver::Error => error
      render_error(error.message, status: :service_unavailable)
    end

    def cancel
      execution_id = params.fetch(:execution_id)
      attempt_number = Integer(params.fetch(:attempt_number))
      reason = cancellation_reason
      cancellation = executor_cancellation_service.cancel(
        idempotency_key: "#{execution_id}:#{attempt_number}",
        reason:
      )

      if cancellation.state == :completed
        return render_error("Executor request already completed", status: :conflict)
      end

      render json: { "status" => "cancelled" }, status: :accepted
    rescue JSON::ParserError => error
      render_error("Invalid JSON: #{error.message}", status: :bad_request)
    rescue KeyError, ArgumentError => error
      render_error(error.message, status: :unprocessable_entity)
    end

    private

    def cancellation_reason
      return "control_plane_cancelled" if request.raw_post.blank?

      payload = JSON.parse(request.raw_post)
      raise ArgumentError, "Cancellation request must be a JSON object" unless payload.is_a?(Hash)

      payload.fetch("reason", "control_plane_cancelled").to_s
    end

    def authenticate_executor_service!
      token = ENV["RUNDIFF_EXECUTOR_SERVICE_TOKEN"].to_s
      if token.empty?
        render_error("Executor service token is not configured", status: :service_unavailable)
        return
      end

      expected = "Bearer #{token}"
      provided = request.authorization.to_s
      authenticated = provided.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(provided, expected)

      render_error("Unauthorized", status: :unauthorized) unless authenticated
    end

    def executor_service
      RunDiff::Executor::Service.new(adapter: executor_service_adapter)
    end

    def executor_cancellation_service
      RunDiff::Executor::Service.new(adapter: nil)
    end

    def executor_service_adapter
      RunDiff::Executor::ServiceResolver.from_env(root: Rails.root)
    end

    def render_error(message, status:)
      render json: { "error" => message }, status:
    end
  end
end
