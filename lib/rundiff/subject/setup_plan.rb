module RunDiff
  module Subject
    class SetupPlan
      Error = Class.new(ArgumentError)

      PHASES = %w[
        bootstrap
        prepare
        start_services
        healthcheck
        stop_services
        cleanup
      ].freeze
      PROVENANCE_VALUES = %w[explicit detected executor_default].freeze

      Step = Data.define(:phase, :operation, :provenance, :details) do
        def initialize(phase:, operation:, provenance:, details: {})
          phase = phase.to_s
          operation = operation.to_s
          provenance = provenance.to_s
          details = stringify_keys(details).freeze

          unless SetupPlan::PHASES.include?(phase)
            raise SetupPlan::Error, "Unsupported setup-plan phase #{phase.inspect}"
          end
          if operation.empty?
            raise SetupPlan::Error, "Setup-plan operation must not be empty"
          end
          unless SetupPlan::PROVENANCE_VALUES.include?(provenance)
            raise SetupPlan::Error, "Unsupported setup-plan provenance #{provenance.inspect}"
          end

          super(phase:, operation:, provenance:, details:)
        end

        def to_h
          {
            "phase" => phase,
            "operation" => operation,
            "provenance" => provenance,
            "details" => details
          }
        end

        private

        def stringify_keys(value)
          value.each_with_object({}) do |(key, item), result|
            result[key.to_s] = normalize(item)
          end
        end

        def normalize(value)
          case value
          when Hash
            stringify_keys(value)
          when Array
            value.map { |item| normalize(item) }.freeze
          else
            value
          end
        end
      end

      attr_reader :framework, :steps, :evidence

      def initialize(framework:, steps:, evidence: {})
        @framework = framework.to_s
        raise Error, "Setup-plan framework must not be empty" if @framework.empty?

        @steps = steps.map { |step| coerce_step(step) }.freeze
        @evidence = evidence.transform_keys(&:to_s).freeze
      end

      def steps_for(phase)
        phase = phase.to_s
        raise Error, "Unsupported setup-plan phase #{phase.inspect}" unless PHASES.include?(phase)

        steps.select { |step| step.phase == phase }
      end

      def to_h
        {
          "framework" => framework,
          "steps" => steps.map(&:to_h),
          "evidence" => evidence
        }
      end

      private

      def coerce_step(step)
        return step if step.is_a?(Step)

        Step.new(**step.transform_keys(&:to_sym))
      end
    end
  end
end
