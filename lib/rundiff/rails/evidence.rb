module RunDiff
  module Rails
    module Evidence
      OBSERVATION_EVENT_NAME = "rundiff.observation.v1"
      EVENT_NAME = OBSERVATION_EVENT_NAME
      ATTRIBUTION_EVENT_NAME = "rundiff.attribution"
      SIDE_EFFECT_SIGNALS = {
        "email" => "emails",
        "background_job" => "background_jobs",
        "http_request" => "http_requests",
        "error" => "errors"
      }.freeze

      def self.observe(signal, execution_id: Current.rundiff_execution_id, run_id: Current.rundiff_run_id,
                       subject: Current.rundiff_subject, source: nil, attributes: {})
        return if execution_id.nil?

        ActiveSupport::Notifications.instrument(
          OBSERVATION_EVENT_NAME,
          execution_id: execution_id.to_s,
          run_id: run_id&.to_s,
          subject: subject&.to_s,
          signal: signal.to_s,
          source: source,
          attributes: attributes,
          occurred_at: Time.current
        )
      end

      def self.side_effect(type, **attributes)
        signal = SIDE_EFFECT_SIGNALS.fetch(type.to_s, type.to_s)
        observe(signal, attributes: attributes)
      end

      def self.attribute_next_line(signal, path:, confidence: "explicit")
        source = caller_locations(1, 1).first
        attribute(
          signal,
          path:,
          line: source.lineno + 1,
          confidence:
        )
      end

      def self.attribute(signal, path:, line:, confidence: "explicit")
        ActiveSupport::Notifications.instrument(
          ATTRIBUTION_EVENT_NAME,
          signal: signal.to_s,
          path: path.to_s,
          start_line: Integer(line),
          end_line: Integer(line),
          confidence: confidence.to_s,
          execution_id: Current.rundiff_execution_id
        )
      end
    end
  end
end
