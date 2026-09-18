module RunDiff
  class ExecutionPair
    def self.call(baseline:, candidate:, changed_paths: [])
      new(baseline:, candidate:, changed_paths:).call
    end

    def initialize(baseline:, candidate:, changed_paths: [])
      @baseline = stringify_keys(baseline)
      @candidate = stringify_keys(candidate)
      @changed_paths = Array(changed_paths).map(&:to_s)
    end

    def call
      validate_identity!
      result = BehavioralDiff.call(
        baseline: @baseline.fetch("measurements"),
        candidate: @candidate.fetch("measurements")
      )
      attach_trusted_sources!(result)

      {
        "schema_version" => "1",
        "run_id" => @baseline.fetch("run_id"),
        "scenario_id" => @baseline.fetch("scenario_id"),
        "executions" => {
          "baseline" => @baseline,
          "candidate" => @candidate
        },
        "result" => result
      }
    end

    private

    def validate_identity!
      return if @baseline.fetch("run_id") == @candidate.fetch("run_id") &&
        @baseline.fetch("scenario_id") == @candidate.fetch("scenario_id")

      raise ArgumentError, "baseline and candidate must share run_id and scenario_id"
    end

    def attach_trusted_sources!(result)
      candidate_attributions = @candidate.fetch("attributions", {})
      baseline_attributions = @baseline.fetch("attributions", {})

      result.fetch("findings").each do |finding|
        signal = finding.fetch("signal")
        source = trusted_source(
          candidate_attributions.fetch(signal, []),
          baseline_attributions.fetch(signal, [])
        )
        finding["source"] = source if source
      end
    end

    def trusted_source(locations, baseline_locations)
      explicit = locations.find do |location|
        location["confidence"] == "explicit" && changed_path?(location)
      end
      return explicit if explicit

      runtime = locations.select do |location|
        location["confidence"] == "runtime" && changed_path?(location)
      end
      return runtime.first if runtime.one?

      baseline_runtime = baseline_locations.select { |location| location["confidence"] == "runtime" }
      candidate_only = runtime.reject do |location|
        baseline_runtime.any? { |baseline_location| same_source?(location, baseline_location) }
      end

      candidate_only.one? ? candidate_only.first : nil
    end

    def same_source?(left, right)
      %w[path start_line end_line confidence].all? { |key| left[key] == right[key] }
    end

    def changed_path?(location)
      @changed_paths.include?(location["path"])
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end
  end
end
