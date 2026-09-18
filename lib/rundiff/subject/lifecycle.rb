module RunDiff
  module Subject
    class Lifecycle
      Session = Data.define(:environment, :env, :setup_plan)

      def initialize(
        discovery:,
        bootstrap: nil,
        environment: nil,
        setup_plan_compiler: nil,
        service_executor: nil
      )
        @discovery = discovery
        @bootstrap = bootstrap
        @environment = environment
        @setup_plan_compiler = setup_plan_compiler
        @service_executor = service_executor || ServiceExecutor.new
      end

      def open(
        root:,
        execution:,
        role:,
        configuration:,
        setup_configuration: configuration,
        sample_index: nil
      )
        setup_plan = compile_setup_plan(root:, configuration: setup_configuration)
        runtime_env = bootstrap(root:, setup_plan:)
        environment = resolve_environment(root:, configuration: setup_configuration, runtime_env:)
        capture_env = nil
        environment_services_attempted = false
        service_session = nil

        begin
          capture_env = prepare_environment(
            environment:,
            root:,
            execution:,
            role:,
            sample_index:
          ).merge(configuration.capture_env)
          service_result = @service_executor.start(
            root:,
            execution:,
            role:,
            env: capture_env,
            setup_plan:
          )
          service_session = service_result.session
          capture_env.merge!(service_result.env)

          environment_services_attempted = true
          environment.start_services(root:, execution:, role:, env: capture_env)
          @service_executor.healthcheck(
            root:,
            execution:,
            role:,
            env: capture_env,
            setup_plan:,
            session: service_session
          )
          environment.healthcheck(root:, execution:, role:, env: capture_env)

          yield Session.new(environment:, env: capture_env, setup_plan:)
        ensure
          begin
            environment.stop_services(root:, execution:, role:, env: capture_env) if environment_services_attempted
          ensure
            begin
              @service_executor.stop(
                root:,
                execution:,
                role:,
                env: capture_env || {},
                setup_plan:,
                session: service_session
              ) if service_session
            ensure
              cleanup_environment(
                environment:,
                root:,
                execution:,
                role:,
                sample_index:
              )
            end
          end
        end
      end

      private

      def prepare_environment(environment:, root:, execution:, role:, sample_index:)
        return environment.prepare(root:, execution:, role:) unless sample_index

        environment.prepare(root:, execution:, role:, sample_index:)
      end

      def cleanup_environment(environment:, root:, execution:, role:, sample_index:)
        return environment.cleanup(root:, execution:, role:) unless sample_index

        environment.cleanup(root:, execution:, role:, sample_index:)
      end

      def compile_setup_plan(root:, configuration:)
        return unless @setup_plan_compiler

        @setup_plan_compiler.call(root:, configuration:)
      end

      def bootstrap(root:, setup_plan:)
        return {} unless @bootstrap

        @bootstrap.call(root:, setup_plan:)
      end

      def resolve_environment(root:, configuration:, runtime_env:)
        return @environment if @environment

        @discovery.resolve(root:, configuration:, runtime_env:)
      end
    end
  end
end
