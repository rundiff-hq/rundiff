module RunDiff
  class RuntimeDiagnosis
    MIN_WALL_MS = 10.0
    CPU_BOUND_RATIO = 70.0
    WAIT_BOUND_RATIO = 30.0

    def self.call(wall_ms:, thread_cpu_ms:)
      wall = numeric(wall_ms)
      thread_cpu = numeric(thread_cpu_ms)
      return unknown if wall.nil? || thread_cpu.nil? || !wall.positive?

      ratio = ((thread_cpu / wall) * 100).round(1)
      classification = if wall < MIN_WALL_MS
        "insufficient_signal"
      elsif ratio >= CPU_BOUND_RATIO
        "cpu_bound"
      elsif ratio <= WAIT_BOUND_RATIO
        "wait_bound"
      else
        "mixed"
      end

      {
        "classification" => classification,
        "cpu_ratio_percent" => ratio,
        "wall_ms" => wall.round(1),
        "thread_cpu_ms" => thread_cpu.round(1)
      }
    end

    def self.unknown
      {
        "classification" => "unknown",
        "cpu_ratio_percent" => nil
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
