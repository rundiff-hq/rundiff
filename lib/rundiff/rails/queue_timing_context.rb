module RunDiff
  module Rails
    class QueueTimingContext
      VERSION = 1
      AUTHORITY = "host_monotonic_same_boot".freeze

      class << self
        def capture(job, clock_domain_id: HostClockDomain.id, monotonic_now: monotonic_now())
          return {} if clock_domain_id.nil? || clock_domain_id.empty?

          {
            "version" => VERSION,
            "clock_domain_id" => clock_domain_id,
            "enqueued_monotonic_seconds" => Float(monotonic_now),
            "scheduled_delay_ms" => declared_schedule_ms(job)
          }
        end

        def measure(context, clock_domain_id: HostClockDomain.id, monotonic_now: monotonic_now())
          context = normalize(context)
          return unless context.fetch("version", nil) == VERSION
          return if clock_domain_id.nil? || clock_domain_id.empty?
          return unless context.fetch("clock_domain_id", nil) == clock_domain_id

          enqueued = Float(context.fetch("enqueued_monotonic_seconds"))
          started = Float(monotonic_now)
          return if started < enqueued

          {
            "queue_wait_ms" => ((started - enqueued) * 1000.0).round(1),
            "scheduled_delay_ms" => Float(context.fetch("scheduled_delay_ms", 0.0)).round(1),
            "timing_authority" => AUTHORITY,
            "clock_domain_id" => clock_domain_id
          }
        rescue ArgumentError, KeyError, TypeError
          nil
        end

        private

        def normalize(context)
          return {} unless context.respond_to?(:to_h)

          context.to_h.transform_keys(&:to_s)
        end

        def declared_schedule_ms(job)
          scheduled_at = job.scheduled_at
          return 0.0 unless scheduled_at

          enqueued_at = job.enqueued_at || Time.current
          [ (scheduled_at.to_f - enqueued_at.to_f) * 1000.0, 0.0 ].max.round(1)
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
