require "pathname"
require_relative "execution_identity"

module RunDiff
  module Subject
    class Discovery
      Error = Class.new(StandardError)

      ADAPTER_MAP = {
        "postgresql" => "postgresql",
        "sqlite" => "sqlite",
        "sqlite3" => "sqlite"
      }.freeze

      def initialize(
        command_runner:,
        postgres_options: {},
        sqlite_options: {},
        execution_identity: ExecutionIdentity.new
      )
        @command_runner = command_runner
        @postgres_options = postgres_options
        @sqlite_options = sqlite_options
        @execution_identity = execution_identity
      end

      def resolve(root:, configuration:, runtime_env: {})
        root = Pathname(root).expand_path
        assert_rails!(root)

        persistence = configuration.persistence
        persistence = discover_persistence(root) if persistence == "auto"

        case persistence
        when "postgresql"
          RailsPostgresEnvironment.new(
            command_runner: @command_runner,
            **@postgres_options,
            runtime_env:
          )
        when "sqlite"
          RailsSqliteEnvironment.new(
            command_runner: @command_runner,
            **@sqlite_options,
            runtime_env:,
            execution_identity: @execution_identity
          )
        else
          raise Error, "Unsupported Rails subject persistence #{persistence.inspect}"
        end
      end

      private

      def assert_rails!(root)
        return if root.join("config", "application.rb").file? && root.join("bin", "rails").file?

        raise Error, "Unsupported subject at #{root}: expected a Rails application with config/application.rb and bin/rails"
      end

      def discover_persistence(root)
        database_file = root.join("config", "database.yml")
        raw_adapters = database_file.file? ? database_file.read.scan(/^\s*adapter:\s*["']?([A-Za-z0-9_-]+)/).flatten.uniq : []
        mapped_adapters = raw_adapters.filter_map { |adapter| ADAPTER_MAP[adapter] }.uniq

        return mapped_adapters.first if mapped_adapters.one? && raw_adapters.all? { |adapter| ADAPTER_MAP.key?(adapter) }

        if raw_adapters.any?
          unsupported = raw_adapters.reject { |adapter| ADAPTER_MAP.key?(adapter) }
          unless unsupported.empty?
            raise Error, "Unsupported Rails database adapter(s): #{unsupported.sort.join(", ")}"
          end

          raise Error, "Ambiguous Rails persistence in config/database.yml: #{mapped_adapters.sort.join(", ")}"
        end

        gem_candidates = persistence_gems(root)
        return gem_candidates.first if gem_candidates.one?

        if gem_candidates.length > 1
          raise Error, "Ambiguous Rails persistence from Gemfile evidence: #{gem_candidates.sort.join(", ")}"
        end

        raise Error, "Could not discover Rails persistence for #{root}; add config/database.yml evidence or set subject.persistence in rundiff.yml"
      end

      def persistence_gems(root)
        contents = [ root.join("Gemfile"), root.join("Gemfile.lock") ]
          .select(&:file?)
          .map(&:read)
          .join("\n")

        candidates = []
        candidates << "postgresql" if contents.match?(/(?:gem\s+["']pg["']|^\s{4}pg \()/m)
        candidates << "sqlite" if contents.match?(/(?:gem\s+["']sqlite3["']|^\s{4}sqlite3 \()/m)
        candidates.uniq
      end
    end
  end
end
