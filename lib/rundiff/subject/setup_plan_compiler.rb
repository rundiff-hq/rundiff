require "pathname"

module RunDiff
  module Subject
    class SetupPlanCompiler
      Error = Class.new(StandardError)

      def initialize(detectors: [ RailsSetupPlanDetector.new ], runtime_capabilities: nil)
        @detectors = detectors.freeze
        @runtime_capabilities = runtime_capabilities
      end

      def call(root:, configuration:)
        plans = @detectors.filter_map do |detector|
          detector.call(root:, configuration:)
        end

        if plans.empty?
          raise Error, "Could not compile a subject setup plan for #{Pathname(root).expand_path}"
        end
        if plans.length > 1
          frameworks = plans.map(&:framework).sort.join(", ")
          raise Error, "Ambiguous subject setup plan for #{Pathname(root).expand_path}: #{frameworks}"
        end

        plan = with_explicit_services(plans.first, configuration:)
        with_executor_capabilities(plan)
      end

      private

      def with_explicit_services(plan, configuration:)
        services = configuration.services
        return plan if services.empty?

        services.each { |service| validate_service_capability!(service) }

        SetupPlan.new(
          framework: plan.framework,
          steps: plan.steps + services.flat_map { |service| service_steps(service) },
          evidence: plan.evidence.merge(
            "explicit_services" => services.map(&:name)
          )
        )
      end

      def validate_service_capability!(service)
        return unless @runtime_capabilities

        case service.type
        when "process"
          validate_service_runtime!(service)
        when "compose"
          validate_compose_provider!(service)
        else
          raise Error, "Unsupported explicit service type #{service.type.inspect}"
        end
      end

      def validate_service_runtime!(service)
        return if @runtime_capabilities.runtime?(service.runtime)

        declared = @runtime_capabilities.runtimes.keys.sort
        declared_text = declared.empty? ? "none" : declared.join(", ")
        raise Error,
          "Explicit service #{service.name.inspect} requires executor runtime #{service.runtime.inspect}; " \
          "declared runtimes: #{declared_text}"
      end

      def validate_compose_provider!(service)
        return if @runtime_capabilities.service_provider?("compose")

        declared = @runtime_capabilities.service_providers.keys.sort
        declared_text = declared.empty? ? "none" : declared.join(", ")
        raise Error,
          "Explicit service #{service.name.inspect} requires executor service provider \"compose\"; " \
          "declared service providers: #{declared_text}"
      end

      def service_steps(service)
        case service.type
        when "process"
          process_service_steps(service)
        when "compose"
          compose_service_steps(service)
        else
          raise Error, "Unsupported explicit service type #{service.type.inspect}"
        end
      end

      def process_service_steps(service)
        [
          {
            phase: "start_services",
            operation: "process.start",
            provenance: "explicit",
            details: {
              name: service.name,
              runtime: service.runtime,
              entrypoint: service.entrypoint,
              args: service.args,
              port_env: service.port_env,
              url_env: service.url_env
            }
          },
          readiness_step(service),
          {
            phase: "stop_services",
            operation: "process.stop",
            provenance: "explicit",
            details: {
              name: service.name
            }
          }
        ]
      end

      def compose_service_steps(service)
        [
          {
            phase: "start_services",
            operation: "compose.run",
            provenance: "explicit",
            details: {
              name: service.name,
              manifest: service.manifest,
              service: service.service,
              target_port: service.target_port,
              url_scheme: service.url_scheme,
              url_env: service.url_env
            }
          },
          readiness_step(service),
          {
            phase: "stop_services",
            operation: "compose.stop",
            provenance: "explicit",
            details: {
              name: service.name
            }
          }
        ]
      end

      def readiness_step(service)
        details = {
          name: service.name,
          url_env: service.url_env,
          timeout_seconds: service.readiness.timeout_seconds
        }
        details[:path] = service.readiness.path if service.readiness.type == "http"

        {
          phase: "healthcheck",
          operation: "#{service.readiness.type}.wait_ready",
          provenance: "explicit",
          details:
        }
      end

      def with_executor_capabilities(plan)
        return plan unless @runtime_capabilities

        SetupPlan.new(
          framework: plan.framework,
          steps: plan.steps,
          evidence: plan.evidence.merge(
            "executor_runtime_capabilities" => @runtime_capabilities.to_h
          )
        )
      end
    end
  end
end
