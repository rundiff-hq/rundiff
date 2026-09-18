module RunDiff
  class AsyncDeltaDiagnosis
    ENQUEUE_TO_START_DOMINANT_SHARE = 70.0
    WORKER_RUNTIME_DOMINANT_SHARE = 30.0

    def self.call(queue_wait:, worker_wall:, scheduled_delay: nil, dispatch_wait: nil)
      if split_available?(scheduled_delay, dispatch_wait)
        return split_call(
          queue_wait:,
          scheduled_delay:,
          dispatch_wait:,
          worker_wall:
        )
      end

      legacy_call(queue_wait:, worker_wall:)
    end

    def self.split_call(queue_wait:, scheduled_delay:, dispatch_wait:, worker_wall:)
      scheduled_delta = numeric(scheduled_delay.fetch("delta"))
      dispatch_delta = numeric(dispatch_wait.fetch("delta"))
      worker_delta = numeric(worker_wall.fetch("delta"))
      return unknown if scheduled_delta.nil? || dispatch_delta.nil? || worker_delta.nil?

      positive_scheduled = [ scheduled_delta, 0.0 ].max
      positive_dispatch = [ dispatch_delta, 0.0 ].max
      positive_worker = [ worker_delta, 0.0 ].max
      positive_total = positive_scheduled + positive_dispatch + positive_worker

      scheduled_share = share(positive_scheduled, positive_total)
      dispatch_share = share(positive_dispatch, positive_total)
      worker_share = share(positive_worker, positive_total)

      classification = split_classification(
        scheduled_delta:,
        dispatch_wait:,
        worker_wall:,
        dispatch_share:,
        worker_share:
      )

      queue_delta = if available?(queue_wait)
        numeric(queue_wait.fetch("delta"))
      else
        scheduled_delta + dispatch_delta
      end

      {
        "classification" => classification,
        "queue_wait_delta_ms" => queue_delta&.round(1),
        "scheduled_delay_delta_ms" => scheduled_delta.round(1),
        "dispatch_wait_delta_ms" => dispatch_delta.round(1),
        "worker_wall_delta_ms" => worker_delta.round(1),
        "positive_async_delta_ms" => positive_total.round(1),
        "scheduled_delay_delta_share_percent" => scheduled_share,
        "dispatch_wait_delta_share_percent" => dispatch_share,
        "worker_runtime_delta_share_percent" => worker_share,
        "enqueue_to_start_delta_share_percent" => positive_total.positive? ? (scheduled_share + dispatch_share).round(1) : nil,
        "dominant_delta_share_percent" => positive_total.positive? ? [ scheduled_share, dispatch_share, worker_share ].max.round(1) : nil
      }
    end
    private_class_method :split_call

    def self.split_classification(scheduled_delta:, dispatch_wait:, worker_wall:, dispatch_share:, worker_share:)
      dispatch_regression = dispatch_wait.fetch("regression", false)
      worker_regression = worker_wall.fetch("regression", false)

      if dispatch_regression && worker_regression
        return "dispatch_wait_regression" if dispatch_share >= ENQUEUE_TO_START_DOMINANT_SHARE
        return "worker_runtime_regression" if worker_share >= ENQUEUE_TO_START_DOMINANT_SHARE

        return "mixed_async_regression"
      end

      return "dispatch_wait_regression" if dispatch_regression
      return "worker_runtime_regression" if worker_regression
      return "scheduled_delay_change" if scheduled_delta.positive?

      "no_async_regression"
    end
    private_class_method :split_classification

    def self.legacy_call(queue_wait:, worker_wall:)
      return unknown unless available?(queue_wait) && available?(worker_wall)

      queue_delta = numeric(queue_wait.fetch("delta"))
      worker_delta = numeric(worker_wall.fetch("delta"))
      return unknown if queue_delta.nil? || worker_delta.nil?

      unless queue_wait.fetch("regression", false) || worker_wall.fetch("regression", false)
        return no_regression(queue_delta:, worker_delta:)
      end

      positive_queue_delta = [ queue_delta, 0.0 ].max
      positive_worker_delta = [ worker_delta, 0.0 ].max
      positive_total = positive_queue_delta + positive_worker_delta
      return unknown if positive_total.zero?

      queue_share = ((positive_queue_delta / positive_total) * 100).round(1)
      classification = if queue_share >= ENQUEUE_TO_START_DOMINANT_SHARE
        "enqueue_to_start_regression"
      elsif queue_share <= WORKER_RUNTIME_DOMINANT_SHARE
        "worker_runtime_regression"
      else
        "mixed_async_regression"
      end

      {
        "classification" => classification,
        "queue_wait_delta_ms" => queue_delta.round(1),
        "worker_wall_delta_ms" => worker_delta.round(1),
        "positive_async_delta_ms" => positive_total.round(1),
        "enqueue_to_start_delta_share_percent" => queue_share,
        "dominant_delta_share_percent" => [ queue_share, 100.0 - queue_share ].max.round(1)
      }
    end
    private_class_method :legacy_call

    def self.split_available?(scheduled_delay, dispatch_wait)
      scheduled_delay && dispatch_wait && available?(scheduled_delay) && available?(dispatch_wait)
    end
    private_class_method :split_available?

    def self.available?(signal)
      signal && signal.fetch("available", true)
    end
    private_class_method :available?

    def self.share(value, total)
      return 0.0 if total.zero?

      ((value / total) * 100).round(1)
    end
    private_class_method :share

    def self.no_regression(queue_delta:, worker_delta:)
      {
        "classification" => "no_async_regression",
        "queue_wait_delta_ms" => queue_delta.round(1),
        "worker_wall_delta_ms" => worker_delta.round(1),
        "positive_async_delta_ms" => [ [ queue_delta, 0.0 ].max + [ worker_delta, 0.0 ].max, 0.0 ].max.round(1),
        "enqueue_to_start_delta_share_percent" => nil,
        "dominant_delta_share_percent" => nil
      }
    end
    private_class_method :no_regression

    def self.unknown
      {
        "classification" => "unknown",
        "queue_wait_delta_ms" => nil,
        "worker_wall_delta_ms" => nil,
        "positive_async_delta_ms" => nil,
        "enqueue_to_start_delta_share_percent" => nil,
        "dominant_delta_share_percent" => nil
      }
    end
    private_class_method :unknown

    def self.numeric(value)
      return value.to_f if value.is_a?(Numeric)

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :numeric
  end
end
