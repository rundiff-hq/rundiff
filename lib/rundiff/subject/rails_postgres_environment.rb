require "pg"
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
        state.sample_isolated
        evidence.sql_queries
        evidence.background_jobs
      ].freeze

      def initialize(
        command_runner:,
        postgres_url: ENV.fetch("RUNDIFF_LOCAL_POSTGRES_URL", DEFAULT_POSTGRES_URL),
        runtime_env: {},
        admin_connection_factory: ->(url) { PG.connect(url) }
      )
        @command_runner = command_runner
        @postgres_url = postgres_url.sub(%r{/+$}, "")
        @runtime_env = runtime_env.transform_keys(&:to_s)
        @admin_connection_factory = admin_connection_factory
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

      def cleanup(root:, execution:, role:, sample_index: nil)
        drop_database(database_name(execution:, role: "#{role}_queue", sample_index:))
        drop_database(database_name(execution:, role:, sample_index:))
      end

      private

      def database_url(execution:, role:, sample_index: nil)
        "#{@postgres_url}/#{database_name(execution:, role:, sample_index:)}"
      end

      def database_name(execution:, role:, sample_index: nil)
        state = StateIdentity.for(execution:, role:, sample_index:)
        "rundiff_app_#{state.suffix}"
      end

      def drop_database(name)
        connection = @admin_connection_factory.call("#{@postgres_url}/postgres")
        connection.exec_params(
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
            "WHERE datname = $1 AND pid <> pg_backend_pid()",
          [ name ]
        )
        connection.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)}")
      ensure
        connection&.close
      end
    end
  end
end
