module RunDiff
  module Rails
    class RuntimeEvidenceBridge
      IGNORED_SQL_NAMES = %w[SCHEMA TRANSACTION CACHE].freeze

      class << self
        def install!
          return if @subscribers

          @subscribers = [
            ActiveSupport::Notifications.subscribe("sql.active_record") { |event| record_sql(event.payload) },
            ActiveSupport::Notifications.subscribe("enqueue.active_job") { observe("background_jobs") },
            ActiveSupport::Notifications.subscribe("enqueue_at.active_job") { observe("background_jobs") },
            ActiveSupport::Notifications.subscribe("deliver.action_mailer") { observe("emails") },
            ActiveSupport::Notifications.subscribe(NetHttpInstrumentation::EVENT_NAME) { observe("http_requests") },
            ActiveSupport::Notifications.subscribe("process_action.action_controller") { |event| record_action(event.payload) }
          ]
        end

        private

        def record_sql(payload)
          return if payload[:cached]
          return if IGNORED_SQL_NAMES.include?(payload[:name].to_s)

          observe("sql_queries")
        end

        def record_action(payload)
          observe("errors") if payload[:exception] || payload[:exception_object]
        end

        def observe(signal)
          return if InternalOperation.active?
          return if Current.rundiff_execution_id.nil?

          source = SourceLocator.call
          source = source&.merge(confidence: "runtime")
          Evidence.observe(signal, source:)
        end
      end
    end
  end
end
