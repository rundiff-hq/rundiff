module RunDiff
  module Rails
    class DurableEvidenceBuffer
      RUNTIME_SIGNALS = {
        wall: "worker_wall_ms",
        process_cpu: "worker_process_cpu_ms",
        thread_cpu: "worker_thread_cpu_ms"
      }.freeze

      class << self
        def capture(execution_id:, producer_kind:, producer_name:, producer_id:)
          events = []
          runtime_started_at = RuntimeProbe.snapshot
          internal_started_at = InternalOperation.snapshot
          subscriber = ActiveSupport::Notifications.subscribe(Evidence::OBSERVATION_EVENT_NAME) do |event|
            payload = event.payload
            next unless payload[:execution_id].to_s == execution_id.to_s

            events << event_attributes(
              payload,
              producer_kind:,
              producer_name:,
              producer_id:
            )
          end

          yield
        rescue StandardError => error
          events << error_attributes(
            execution_id:,
            producer_kind:,
            producer_name:,
            producer_id:,
            error:
          )
          raise
        ensure
          events&.concat(
            runtime_attributes(
              execution_id:,
              producer_kind:,
              producer_name:,
              producer_id:,
              runtime_started_at:,
              internal_started_at:
            )
          ) if runtime_started_at && internal_started_at
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
          persist(events) if events&.any?
        end

        def record_runtime_metric(execution_id:, signal:, value:, producer_kind:, producer_name:, producer_id:, attributes: {})
          now = Time.current
          persist([
            event_row(
              execution_id:,
              run_id: Current.rundiff_run_id,
              subject: Current.rundiff_subject,
              signal:,
              path: nil,
              start_line: nil,
              end_line: nil,
              confidence: "runtime",
              payload: { "value" => value }.merge(attributes.transform_keys(&:to_s)),
              producer_kind:,
              producer_name:,
              producer_id:,
              occurred_at: now,
              now:
            )
          ])
        end

        def persisting?
          InternalOperation.active?
        end

        private

        def event_attributes(payload, producer_kind:, producer_name:, producer_id:)
          source = payload[:source] || {}
          now = Time.current

          event_row(
            execution_id: payload.fetch(:execution_id),
            run_id: payload[:run_id],
            subject: payload[:subject],
            signal: payload.fetch(:signal),
            path: source[:path],
            start_line: source[:start_line],
            end_line: source[:end_line],
            confidence: source[:confidence],
            payload: payload[:attributes] || {},
            producer_kind:,
            producer_name:,
            producer_id:,
            occurred_at: payload[:occurred_at] || now,
            now:
          )
        end

        def error_attributes(execution_id:, producer_kind:, producer_name:, producer_id:, error:)
          now = Time.current

          event_row(
            execution_id:,
            run_id: Current.rundiff_run_id,
            subject: Current.rundiff_subject,
            signal: "errors",
            path: nil,
            start_line: nil,
            end_line: nil,
            confidence: nil,
            payload: { "error_class" => error.class.name },
            producer_kind:,
            producer_name:,
            producer_id:,
            occurred_at: now,
            now:
          )
        end

        def runtime_attributes(execution_id:, producer_kind:, producer_name:, producer_id:, runtime_started_at:, internal_started_at:)
          elapsed = RuntimeProbe.elapsed_ms(
            runtime_started_at,
            subtract_seconds: InternalOperation.delta_since(internal_started_at)
          )
          now = Time.current

          elapsed.filter_map do |metric, value|
            signal = RUNTIME_SIGNALS[metric]
            next unless signal

            event_row(
              execution_id:,
              run_id: Current.rundiff_run_id,
              subject: Current.rundiff_subject,
              signal:,
              path: nil,
              start_line: nil,
              end_line: nil,
              confidence: "runtime",
              payload: { "value" => value },
              producer_kind:,
              producer_name:,
              producer_id:,
              occurred_at: now,
              now:
            )
          end
        end

        def event_row(execution_id:, run_id:, subject:, signal:, path:, start_line:, end_line:, confidence:,
                      payload:, producer_kind:, producer_name:, producer_id:, occurred_at:, now:)
          {
            execution_id: execution_id.to_s,
            run_id: run_id&.to_s,
            subject: subject&.to_s,
            signal: signal.to_s,
            path: path&.to_s,
            start_line:,
            end_line:,
            confidence: confidence&.to_s,
            payload:,
            producer_kind: producer_kind.to_s,
            producer_name: producer_name.to_s,
            producer_id: producer_id&.to_s,
            occurred_at:,
            created_at: now,
            updated_at: now
          }
        end

        def persist(events)
          InternalOperation.call do
            RunDiffEvidenceEvent.insert_all!(events)
          end
        end
      end
    end
  end
end
