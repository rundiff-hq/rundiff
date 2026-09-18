module RunDiff
  class Comparison
    RECOMMENDATION_ORDER = { "allow" => 0, "review" => 1, "block" => 2 }.freeze

    def self.call(baseline:, candidates:)
      new(baseline:, candidates:).call
    end

    def initialize(baseline:, candidates:)
      @baseline = stringify_keys(baseline)
      @candidates = candidates.map { |candidate| stringify_keys(candidate) }
    end

    def call
      compared = @candidates.map { |candidate| compare(candidate) }

      {
        "schema_version" => "1",
        "baseline" => @baseline,
        "candidates" => compared,
        "ranking" => rank(compared)
      }
    end

    private

    def compare(candidate)
      candidate.merge(
        "result" => BehavioralDiff.call(
          baseline: @baseline.fetch("measurements"),
          candidate: candidate.fetch("measurements")
        )
      )
    end

    def rank(candidates)
      candidates.sort_by do |candidate|
        result = candidate.fetch("result")
        [
          RECOMMENDATION_ORDER.fetch(result.fetch("merge_recommendation"), 99),
          result.fetch("findings").size
        ]
      end.map { |candidate| candidate.fetch("id") }
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end
  end
end
