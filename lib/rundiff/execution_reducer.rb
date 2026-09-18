require_relative "async_diagnosis"
require_relative "runtime_diagnosis"

module RunDiff
  class ExecutionReducer
    COUNTABLE_SIGNALS = %w[sql_queries background_jobs emails http_requests errors].freeze
    SUMMABLE_RUNTIME_SIGNALS = %w[worker_wall_ms worker_process_cpu_ms worker_thread_cpu_ms].freeze
    MAX_RUNTIME_SIGNALS = %w[queue_wait_ms scheduled_delay_ms dispatch_wait_ms].freeze

    def self.call(execution:)
      new(execution:).call
    end

    def initialize(execution:)
      @execution = deep_stringify_keys(execution)
    end

    def call
      measurements = @execution.fetch("measurements").dup
      attributions = normalized_attributions(@execution.fetch("attributions", {}))

      durable_observations.each do |observation|
        signal = observation.fetch("signal")
        fold_measurement!(measurements, signal, observation)
        append_attribution(attributions, signal, observation)
      end

      normalize_numeric_measurements!(measurements)

      @execution.merge(
        "measurements" => measurements,
        "attributions" => attributions,
        "runtime_profile" => runtime_profile(measurements),
        "evidence" => {
          "foreground" => true,
          "durable_observations" => durable_observations.size
        }
      )
    end

    private

    def durable_observations
      @durable_observations ||= Array(@execution["durable_observations"]).map { |observation| deep_stringify_keys(observation) }
    end

    def fold_measurement!(measurements, signal, observation)
      if COUNTABLE_SIGNALS.include?(signal)
        measurements[signal] = measurements.fetch(signal, 0).to_f + 1
      elsif SUMMABLE_RUNTIME_SIGNALS.include?(signal)
        value = numeric_runtime_value(observation)
        measurements[signal] = measurements.fetch(signal, 0).to_f + value if value
      elsif MAX_RUNTIME_SIGNALS.include?(signal)
        value = numeric_runtime_value(observation)
        current = measurements[signal]
        measurements[signal] = value if value && (current.nil? || value > current.to_f)
      end
    end

    def numeric_runtime_value(observation)
      Float(observation.dig("payload", "value"))
    rescue ArgumentError, TypeError
      nil
    end

    def append_attribution(attributions, signal, observation)
      return unless observation["path"] && observation["start_line"] && observation["end_line"]

      location = {
        "path" => observation.fetch("path"),
        "start_line" => Integer(observation.fetch("start_line")),
        "end_line" => Integer(observation.fetch("end_line")),
        "confidence" => observation.fetch("confidence", "runtime")
      }
      attributions[signal] ||= []
      attributions[signal] << location unless attributions[signal].include?(location)
    end

    def normalized_attributions(attributions)
      attributions.each_with_object({}) do |(signal, locations), result|
        result[signal.to_s] = Array(locations).map { |location| deep_stringify_keys(location) }
      end
    end

    def normalize_numeric_measurements!(measurements)
      measurements.each do |signal, value|
        if COUNTABLE_SIGNALS.include?(signal) && value.is_a?(Float) && value.to_i == value
          measurements[signal] = value.to_i
        elsif (SUMMABLE_RUNTIME_SIGNALS + MAX_RUNTIME_SIGNALS).include?(signal)
          measurements[signal] = value.to_f.round(1)
        end
      end
    end

    def runtime_profile(measurements)
      {
        "request" => RuntimeDiagnosis.call(
          wall_ms: measurements["duration_ms"],
          thread_cpu_ms: measurements["thread_cpu_ms"]
        ),
        "async" => AsyncDiagnosis.call(
          queue_wait_ms: measurements["queue_wait_ms"],
          worker_wall_ms: measurements["worker_wall_ms"]
        ),
        "worker" => RuntimeDiagnosis.call(
          wall_ms: measurements["worker_wall_ms"],
          thread_cpu_ms: measurements["worker_thread_cpu_ms"]
        )
      }
    end

    def deep_stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          result[key.to_s] = deep_stringify_keys(nested)
        end
      when Array
        value.map { |nested| deep_stringify_keys(nested) }
      else
        value
      end
    end
  end
end
