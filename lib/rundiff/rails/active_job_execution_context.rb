module RunDiff
  module Rails
    module ActiveJobExecutionContext
      CONTEXT_KEY = "rundiff_execution_context"
      QUEUE_TIMING_KEY = "rundiff_queue_timing"
      CONTEXT_ATTRIBUTES = %w[rundiff_execution_id rundiff_run_id rundiff_subject].freeze
      QUEUE_STAGE_SEMANTICS = {
        "queue_wait_ms" => "enqueue_to_start",
        "scheduled_delay_ms" => "enqueue_to_eligibility",
        "dispatch_wait_ms" => "eligibility_to_start"
      }.freeze

      def self.included(base)
        base.before_enqueue do |job|
          job.send(:register_rundiff_work_item)
        end

        base.around_perform do |job, block|
          job.send(:with_rundiff_execution_context) do
            job.send(:capture_rundiff_worker_evidence, &block)
          end
        end
      end

      def serialize
        payload = super.merge(CONTEXT_KEY => rundiff_execution_context)
        timing_context = rundiff_queue_timing_context
        payload[QUEUE_TIMING_KEY] = timing_context if timing_context.present?
        payload
      end

      def deserialize(job_data)
        @rundiff_execution_context = normalize_rundiff_execution_context(job_data[CONTEXT_KEY])
        @rundiff_queue_timing_context = normalize_rundiff_queue_timing_context(job_data[QUEUE_TIMING_KEY])
        super
      end

      private

      def rundiff_execution_context
        @rundiff_execution_context ||= CONTEXT_ATTRIBUTES.each_with_object({}) do |attribute, context|
          value = Current.public_send(attribute)
          context[attribute] = value unless value.nil?
        end
      end

      def rundiff_queue_timing_context
        return @rundiff_queue_timing_context if defined?(@rundiff_queue_timing_context) && @rundiff_queue_timing_context.present?
        return {} if rundiff_execution_context["rundiff_execution_id"].blank?

        @rundiff_queue_timing_context = QueueTimingContext.capture(self)
      end

      def normalize_rundiff_execution_context(context)
        return {} unless context.respond_to?(:to_h)

        context.to_h.slice(*CONTEXT_ATTRIBUTES).transform_keys(&:to_s)
      end

      def normalize_rundiff_queue_timing_context(context)
        return {} unless context.respond_to?(:to_h)

        context.to_h.transform_keys(&:to_s)
      end

      def register_rundiff_work_item
        context = rundiff_execution_context
        return if context["rundiff_execution_id"].blank?

        @rundiff_queue_timing_context = QueueTimingContext.capture(self)
        ExecutionWorkLifecycle.enqueued(self, context:)
      end

      def with_rundiff_execution_context
        context = @rundiff_execution_context
        return yield if context.nil? || context.empty?

        Current.set(**context.transform_keys(&:to_sym)) { yield }
      end

      def capture_rundiff_worker_evidence
        execution_id = Current.rundiff_execution_id
        return yield if execution_id.nil?

        ExecutionWorkLifecycle.running(self)
        record_rundiff_queue_stages
        result = DurableEvidenceBuffer.capture(
          execution_id:,
          producer_kind: "active_job",
          producer_name: self.class.name,
          producer_id: job_id
        ) { yield }
        ExecutionWorkLifecycle.completed(self)
        result
      rescue StandardError => error
        ExecutionWorkLifecycle.failed(self, error:)
        raise
      end

      def record_rundiff_queue_stages
        measurement = QueueTimingContext.measure(@rundiff_queue_timing_context)
        return unless measurement

        timing = QueueStageTiming.call(
          queue_wait_ms: measurement.fetch("queue_wait_ms"),
          scheduled_delay_ms: measurement.fetch("scheduled_delay_ms")
        )

        timing.each do |signal, value|
          next if value.nil?

          DurableEvidenceBuffer.record_runtime_metric(
            execution_id: Current.rundiff_execution_id,
            signal:,
            value:,
            producer_kind: "active_job",
            producer_name: self.class.name,
            producer_id: job_id,
            attributes: {
              semantics: QUEUE_STAGE_SEMANTICS.fetch(signal),
              timing_authority: measurement.fetch("timing_authority"),
              clock_domain_id: measurement.fetch("clock_domain_id")
            }
          )
        end
      end
    end
  end
end
