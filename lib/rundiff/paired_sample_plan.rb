module RunDiff
  class PairedSamplePlan
    Error = Class.new(StandardError)
    Step = Data.define(:sample_index, :role, :position)

    def self.call(sample_count:)
      new(sample_count:).call
    end

    def initialize(sample_count:)
      @sample_count = Integer(sample_count)
      raise Error, "sample_count must be positive" unless @sample_count.positive?
    rescue ArgumentError, TypeError
      raise Error, "sample_count must be a positive integer"
    end

    def call
      (1..@sample_count).flat_map do |sample_index|
        roles = sample_index.odd? ? %w[base candidate] : %w[candidate base]

        roles.each_with_index.map do |role, position|
          Step.new(
            sample_index:,
            role:,
            position: position + 1
          )
        end
      end
    end
  end
end
