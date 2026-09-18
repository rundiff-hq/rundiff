module RunDiff
  module Executor
    class Cancellation
      def initialize(notification_job: RunDiffExecutorCancellationJob)
        @notification_job = notification_job
      end

      def call(execution:, reason: "cancelled")
        attempt_number = execution.attempt_count
        return false unless execution.cancel!(attempt_number:, reason:)
        return true unless attempt_number.positive?

        begin
          @notification_job.perform_later(execution.execution_id, attempt_number, reason.to_s)
        rescue StandardError => error
          ::Rails.logger.warn(
            "RunDiff executor cancellation enqueue failed execution_id=#{execution.execution_id.inspect} " \
            "attempt=#{attempt_number.inspect} error=#{error.class}"
          )
        end

        true
      end
    end
  end
end
