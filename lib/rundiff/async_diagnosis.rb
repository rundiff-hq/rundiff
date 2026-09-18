module RunDiff
  class AsyncDiagnosis
    MIN_TOTAL_MS = 10.0
    QUEUE_BOUND_SHARE = 70.0
    WORKER_BOUND_SHARE = 30.0

    def self.call(queue_wait_ms:, worker_wall_ms:)
      queue_wait = numeric(queue_wait_ms)
      worker_wall = numeric(worker_wall_ms)
      return unknown if queue_wait.nil? || worker_wall.nil?

      total = queue_wait + worker_wall
      return insufficient(queue_wait:, worker_wall:, total:) if total < MIN_TOTAL_MS

      queue_share = ((queue_wait / total) * 100).round(1)
      classification = if queue_share >= QUEUE_BOUND_SHARE
        "queue_bound"
      elsif queue_share <= WORKER_BOUND_SHARE
        "worker_bound"
      else
        "mixed_async"
      end

      {
        "classification" => classification,
        "queue_share_percent" => queue_share,
        "queue_wait_ms" => queue_wait.round(1),
        "worker_wall_ms" => worker_wall.round(1),
        "async_total_ms" => total.round(1)
      }
    end

    def self.insufficient(queue_wait:, worker_wall:, total:)
      {
        "classification" => "insufficient_signal",
        "queue_share_percent" => total.positive? ? ((queue_wait / total) * 100).round(1) : nil,
        "queue_wait_ms" => queue_wait.round(1),
        "worker_wall_ms" => worker_wall.round(1),
        "async_total_ms" => total.round(1)
      }
    end
    private_class_method :insufficient

    def self.unknown
      {
        "classification" => "unknown",
        "queue_share_percent" => nil
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
