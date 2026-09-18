module RunDiff
  class PairedTimingSamples
    Error = Class.new(StandardError)
    DEFAULT_MIN_SAMPLES = 3

    def self.call(baseline_samples:, candidate_samples:, min_samples: DEFAULT_MIN_SAMPLES)
      new(
        baseline_samples:,
        candidate_samples:,
        min_samples:
      ).call
    end

    def initialize(baseline_samples:, candidate_samples:, min_samples:)
      @baseline_samples = normalize_samples(baseline_samples, label: "baseline")
      @candidate_samples = normalize_samples(candidate_samples, label: "candidate")
      @min_samples = Integer(min_samples)

      raise Error, "min_samples must be positive" unless @min_samples.positive?
      unless @baseline_samples.length == @candidate_samples.length
        raise Error,
          "paired timing samples must have equal lengths: "           "baseline=#{@baseline_samples.length} candidate=#{@candidate_samples.length}"
      end
      raise Error, "paired timing samples must not be empty" if @baseline_samples.empty?
    end

    def call
      baseline_median = median(@baseline_samples)
      candidate_median = median(@candidate_samples)
      paired_deltas = @candidate_samples.zip(@baseline_samples).map do |candidate, baseline|
        candidate - baseline
      end
      median_delta = median(paired_deltas)

      {
        "sample_count" => @baseline_samples.length,
        "sample_quality" => sample_quality,
        "baseline_median" => round(baseline_median),
        "candidate_median" => round(candidate_median),
        "median_delta" => round(median_delta),
        "delta_percent" => percentage_delta(baseline_median, median_delta),
        "delta_mad" => round(median_absolute_deviation(paired_deltas))
      }
    end

    private

    def normalize_samples(samples, label:)
      Array(samples).map.with_index do |value, index|
        number = Float(value)
        unless number.finite?
          raise Error, "#{label} sample #{index} must be finite"
        end
        number
      rescue ArgumentError, TypeError
        raise Error, "#{label} sample #{index} must be numeric"
      end
    end

    def sample_quality
      @baseline_samples.length >= @min_samples ? "sampled" : "insufficient_samples"
    end

    def median(values)
      sorted = values.sort
      midpoint = sorted.length / 2

      if sorted.length.odd?
        sorted.fetch(midpoint)
      else
        (sorted.fetch(midpoint - 1) + sorted.fetch(midpoint)) / 2.0
      end
    end

    def median_absolute_deviation(values)
      center = median(values)
      median(values.map { |value| (value - center).abs })
    end

    def percentage_delta(baseline, delta)
      return nil if baseline.zero?

      round((delta / baseline) * 100.0)
    end

    def round(value)
      value.round(3)
    end
  end
end
