require_relative "state_identity"
require "fileutils"
require "rbconfig"
require_relative "execution_identity"

module RunDiff
  module Subject
    class RailsSqliteEnvironment < Environment
      CAPABILITIES = %w[
        framework.rails
        persistence.sqlite
        queue.active_job_test_adapter
        telemetry.subject_owned_rails
        runtime.local_process
        state.isolated_comparable
        evidence.sql_queries
        evidence.background_jobs
      ].freeze

      def initialize(
        command_runner:,
        state_root: nil,
        bundle_path: nil,
        bundle_app_config: nil,
        runtime_env: {},
        execution_identity: ExecutionIdentity.new
      )
        @command_runner = command_runner
        @state_root = state_root && Pathname(state_root).expand_path
        @bundle_path = bundle_path && Pathname(bundle_path).expand_path.to_s
        @bundle_app_config = bundle_app_config && Pathname(bundle_app_config).expand_path.to_s
        @runtime_env = runtime_env.transform_keys(&:to_s)
        @execution_identity = execution_identity
      end

      def capabilities
        CAPABILITIES
      end

      def prepare(root:, execution:, role:, sample_index: nil)
        path = database_path(root:, execution:, role:, sample_index:)
        FileUtils.mkdir_p(path.dirname)
        @execution_identity.prepare_tree(path.dirname)
        remove_database_files(path)

        env = env_for(root:, execution:, role:, sample_index:)
        @command_runner.call(
          env:,
          command: [ RbConfig.ruby, root.join("bin", "rails").to_s, "db:prepare", "--trace" ],
          chdir: root.to_s
        )
        env
      end

      def env_for(root:, execution:, role:, sample_index: nil)
        env = @runtime_env.merge(
          "BUNDLE_GEMFILE" => root.join("Gemfile").to_s,
          "DATABASE_URL" => nil,
          "SOLID_QUEUE_DATABASE_URL" => nil,
          "RAILS_ENV" => "test",
          "RUNDIFF_SQLITE_DATABASE" => database_path(root:, execution:, role:, sample_index:).to_s,
          "RUNDIFF_ASYNC_TRANSPORT" => "test_adapter",
          "RUNDIFF_QUIESCENCE_TIMEOUT_SECONDS" => "30",
          "RUNDIFF_QUIET_PERIOD_SECONDS" => "0.01"
        )
        env["BUNDLE_PATH"] = @bundle_path if @bundle_path
        env["BUNDLE_APP_CONFIG"] = @bundle_app_config if @bundle_app_config
        env
      end

      def cleanup(root:, execution:, role:, sample_index: nil)
        remove_database_files(database_path(root:, execution:, role:, sample_index:))
      end

      private

      def database_path(root:, execution:, role:, sample_index: nil)
        directory = @state_root || root.join("tmp", "rundiff", "sqlite")
        state = StateIdentity.for(execution:, role:, sample_index:)
        directory.join("rundiff_subject_#{state.suffix}.sqlite3")
      end

      def remove_database_files(path)
        FileUtils.rm_f(path)
        FileUtils.rm_f("#{path}-wal")
        FileUtils.rm_f("#{path}-shm")
      end
    end
  end
end
