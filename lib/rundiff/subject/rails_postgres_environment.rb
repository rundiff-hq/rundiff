require_relative "state_identity"
module RunDiff
  module Subject
    class RailsPostgresEnvironment < Environment
      DEFAULT_POSTGRES_URL = "postgres://localhost".freeze
      CAPABILITIES = %w[
        framework.rails
        persistence.postgresql
        queue.solid_queue
        telemetry.subject_owned_rails
        runtime.local_process
        state.isolated_comparable
        evidence.sql_queries
        evidence.background_jobs
      ].freeze

      def initialize(
        command_runner:,
        postgres_url: ENV.fetch("RUNDIFF_LOCAL_POSTGRES_URL", DEFAULT_POSTGRES_URL),
        runtime_env: {}
      )
        @command_runner = command_runner
        @postgres_url = postgres_url.sub(%r{/+$}, "")
        @runtime_env = runtime_env.transform_keys(&:to_s)
      end

      def capabilities
        CAPABILITIES
      end

      def prepare(root:, execution:, role:, sample_index: nil)
        env = env_for(root:, execution:, role:, sample_index:)
        @command_runner.call(
          env:,
          command: [ root.join("bin", "rails").to_s, "db:prepare", "--trace" ],
          chdir: root.to_s
        )
        env
      end

      def env_for(root:, execution:, role:, sample_index: nil)
        @runtime_env.merge(
          "BUNDLE_GEMFILE" => root.join("Gemfile").to_s,
          "RAILS_ENV" => "test",
          "DATABASE_URL" => database_url(execution:, role:, sample_index:),
          "SOLID_QUEUE_DATABASE_URL" => database_url(execution:, role: "#{role}_queue", sample_index:),
          "RUNDIFF_SOLID_QUEUE" => "1",
          "RUNDIFF_ASYNC_TRANSPORT" => "solid_queue",
          "RUNDIFF_SOLID_QUEUE_DIAGNOSTICS" => "1",
          "RUNDIFF_SOLID_QUEUE_START_TIMEOUT_SECONDS" => "30",
          "RUNDIFF_QUIESCENCE_TIMEOUT_SECONDS" => "30",
          "SOLID_QUEUE_SKIP_RECURRING" => "true",
          "SOLID_QUEUE_SUPERVISOR_MODE" => "async"
        )
      end

      private

      def database_url(execution:, role:, sample_index: nil)
        state = StateIdentity.for(execution:, role:, sample_index:)
        "#{@postgres_url}/rundiff_app_#{state.suffix}"
      end
    end
  end
end
