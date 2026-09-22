module RunDiff
  module Subject
    class Lifecycle
      Session = Data.define(:environment, :env, :setup_plan)

      def initialize(
        discovery:,
        bootstrap: nil,
        environment: nil,
        setup_plan_compiler: nil,
        service_executor: nil,
        stage_timer: nil
      )
        @discovery = discovery
        @bootstrap = bootstrap
        @environment = environment
        @setup_plan_compiler = setup_plan_compiler
        @service_executor = service_executor || ServiceExecutor.new
        @stage_timer = stage_timer
      end

      def open(
        root:,
        execution:,
        role:,
        configuration:,
        setup_configuration: configuration,
        runtime_env: nil,
        prepared_env: nil,
        services_prepared: false
      )
        setup_plan = timed(execution:, role:, stage: "setup_plan") do
          compile_setup_plan(root:, configuration: setup_configuration)
        end
        runtime_env = timed(execution:, role:, stage: "bootstrap") do
          bootstrap(root:, setup_plan:)
        end if runtime_env.nil?
        runtime_env ||= {}
        environment = timed(execution:, role:, stage: "environment_resolve") do
          resolve_environment(root:, configuration: setup_configuration, runtime_env:)
        end
        capture_env = nil
        environment_services_attempted = false
        service_session = nil

        begin
          capture_env = if prepared_env
            prepared_env.dup
          else
            timed(execution:, role:, stage: "environment_prepare") do
              environment.prepare(root:, execution:, role:)
            end
          end.merge(configuration.capture_env)
          unless services_prepared
            service_result = timed(execution:, role:, stage: "services_start") do
              @service_executor.start(
                root:,
                execution:,
                role:,
                env: capture_env,
                setup_plan:
              )
            end
            service_session = service_result.session
            capture_env.merge!(service_result.env)
          end

          environment_services_attempted = true
          environment.start_services(root:, execution:, role:, env: capture_env)
          unless services_prepared
            @service_executor.healthcheck(
              root:,
              execution:,
              role:,
              env: capture_env,
              setup_plan:,
              session: service_session
            )
          end
          environment.healthcheck(root:, execution:, role:, env: capture_env)

          timed(execution:, role:, stage: "capture") do
            yield Session.new(environment:, env: capture_env, setup_plan:)
          end
        ensure
          timed(execution:, role:, stage: "cleanup") do
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
                environment.cleanup(root:, execution:, role:)
              end
            end
          end
        end
      end

      private

      def timed(execution:, role:, stage:, &block)
        return yield unless @stage_timer

        @stage_timer.measure(
          execution_id: execution.execution_id,
          stage:,
          role:,
          &block
        )
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
