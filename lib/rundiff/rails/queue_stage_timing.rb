module RunDiff
  module Rails
    class QueueStageTiming
      def self.call(enqueued_at: nil, started_at: nil, scheduled_at: nil, queue_wait_ms: nil, scheduled_delay_ms: nil)
        if queue_wait_ms
          return from_durations(
            queue_wait_ms:,
            scheduled_delay_ms: scheduled_delay_ms || 0.0
          )
        end

        return unavailable unless enqueued_at && started_at

        queue_wait_ms = milliseconds(started_at - enqueued_at)
        declared_schedule_ms = scheduled_at ? milliseconds(scheduled_at - enqueued_at) : 0.0
        from_durations(queue_wait_ms:, scheduled_delay_ms: declared_schedule_ms)
      end

      def self.from_durations(queue_wait_ms:, scheduled_delay_ms:)
        queue_wait_ms = [ Float(queue_wait_ms), 0.0 ].max.round(1)
        scheduled_delay_ms = [ [ Float(scheduled_delay_ms), 0.0 ].max, queue_wait_ms ].min.round(1)

        {
          "queue_wait_ms" => queue_wait_ms,
          "scheduled_delay_ms" => scheduled_delay_ms,
          "dispatch_wait_ms" => [ queue_wait_ms - scheduled_delay_ms, 0.0 ].max.round(1)
        }
      rescue ArgumentError, TypeError
        unavailable
      end
      private_class_method :from_durations

      def self.milliseconds(seconds)
        [ seconds.to_f * 1000.0, 0.0 ].max.round(1)
      end
      private_class_method :milliseconds

      def self.unavailable
        {
          "queue_wait_ms" => nil,
          "scheduled_delay_ms" => nil,
          "dispatch_wait_ms" => nil
        }
      end
      private_class_method :unavailable
    end
  end
end
