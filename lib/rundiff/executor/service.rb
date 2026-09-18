module RunDiff
  module Executor
    class Service
      Error = Class.new(StandardError)
      RequestConflict = Class.new(Error)
      RequestInProgress = Class.new(Error)
      RequestCancelled = Class.new(Error)
      ClaimLost = Class.new(Error)

      def initialize(adapter:, request_model: RunDiffExecutorRequest, lease_seconds: nil)
        @adapter = adapter
        @request_model = request_model
        @lease_seconds = Integer(
          lease_seconds || ENV.fetch("RUNDIFF_EXECUTOR_SERVICE_REQUEST_LEASE_SECONDS", RunDiffExecutorRequest::DEFAULT_LEASE_SECONDS)
        )
      end

      def call(idempotency_key:, request_payload:, repository_capability: nil)
        request = Request.from_h(request_payload)
        validate_idempotency_key!(idempotency_key:, request:)
        canonical_payload = request.to_h
        acquisition = acquire(idempotency_key:, request_payload: canonical_payload)

        case acquisition.state
        when :completed
          Result.from_h(acquisition.record.result)
        when :cancelled
          raise RequestCancelled, "Executor request was cancelled"
        when :in_progress
          raise RequestInProgress, "Executor request is already processing"
        when :execute
          execute_and_complete(acquisition:, request:, repository_capability:)
        else
          raise Error, "Unsupported executor request acquisition state #{acquisition.state.inspect}"
        end
      end

      def cancel(idempotency_key:, reason: "cancelled")
        @request_model.cancel!(idempotency_key:, reason:)
      end

      private

      def validate_idempotency_key!(idempotency_key:, request:)
        expected = "#{request.execution_id}:#{request.attempt_number}"
        return if idempotency_key == expected

        raise ArgumentError, "Idempotency-Key must match the execution id and attempt number"
      end

      def acquire(idempotency_key:, request_payload:)
        @request_model.acquire!(
          idempotency_key:,
          request_payload:,
          lease_seconds: @lease_seconds
        )
      rescue RunDiffExecutorRequest::DigestMismatch => error
        raise RequestConflict, error.message
      end

      def execute_and_complete(acquisition:, request:, repository_capability:)
        result = @adapter.call(request:, repository_capability:)
        unless result.is_a?(Result)
          result = Result.failure(TypeError.new("Executor service adapter must return RunDiff::Executor::Result"))
        end

        return result if acquisition.record.complete_claim!(
          claim_token: acquisition.claim_token,
          result_payload: result.to_h
        )

        resolve_lost_claim!(record_id: acquisition.record.id, fallback: "Executor request claim expired before completion")
      rescue StandardError => error
        raise if error.is_a?(Error)

        result = Result.failure(error)
        return result if acquisition.record.complete_claim!(
          claim_token: acquisition.claim_token,
          result_payload: result.to_h
        )

        resolve_lost_claim!(
          record_id: acquisition.record.id,
          fallback: "Executor request claim expired while handling a worker failure"
        )
      end

      def resolve_lost_claim!(record_id:, fallback:)
        current = @request_model.find(record_id)
        return Result.from_h(current.result) if current.status == "completed"
        raise RequestCancelled, "Executor request was cancelled" if current.status == "cancelled"

        raise ClaimLost, fallback
      end
    end
  end
end
