require "json"

module RunDiff
  module Subject
    class RuntimeCapabilities
      Error = Class.new(ArgumentError)
      ENV_KEY = "RUNDIFF_EXECUTOR_CAPABILITIES_JSON"

      attr_reader :runtimes, :package_managers, :service_providers

      def self.ruby_only(version: RUBY_VERSION)
        new(runtimes: { "ruby" => version }, package_managers: {}, service_providers: {})
      end

      def self.from_env(env: ENV, ruby_version: RUBY_VERSION)
        raw = env[ENV_KEY].to_s.strip
        return ruby_only(version: ruby_version) if raw.empty?

        payload = JSON.parse(raw)
        unless payload.is_a?(Hash)
          raise Error, "#{ENV_KEY} must contain a JSON object"
        end

        new(
          runtimes: payload.fetch("runtimes", {}),
          package_managers: payload.fetch("package_managers", {}),
          service_providers: payload.fetch("service_providers", {})
        )
      rescue JSON::ParserError => error
        raise Error, "Invalid #{ENV_KEY}: #{error.message}"
      end

      def initialize(runtimes:, package_managers:, service_providers: {})
        @runtimes = normalize_mapping(runtimes, kind: "runtime").freeze
        @package_managers = normalize_mapping(package_managers, kind: "package manager").freeze
        @service_providers = normalize_mapping(service_providers, kind: "service provider").freeze
      end

      def runtime?(name)
        runtimes.key?(name.to_s)
      end

      def package_manager?(name)
        package_managers.key?(name.to_s)
      end

      def service_provider?(name)
        service_providers.key?(name.to_s)
      end

      def runtime_version(name)
        runtimes[name.to_s]
      end

      def package_manager_version(name)
        package_managers[name.to_s]
      end

      def service_provider_version(name)
        service_providers[name.to_s]
      end

      def with_service_provider(name, version)
        name = name.to_s
        version = version.to_s
        existing = service_providers[name]
        if existing && existing != version
          raise Error,
            "Executor service provider capability #{name.inspect} conflicts: " \
            "declared=#{existing.inspect} discovered=#{version.inspect}"
        end

        self.class.new(
          runtimes:,
          package_managers:,
          service_providers: service_providers.merge(name => version)
        )
      end

      def to_h
        {
          "runtimes" => runtimes,
          "package_managers" => package_managers,
          "service_providers" => service_providers
        }
      end

      private

      def normalize_mapping(value, kind:)
        unless value.is_a?(Hash)
          raise Error, "Executor #{kind} capabilities must be a mapping"
        end

        value.each_with_object({}) do |(name, version), result|
          name = name.to_s.strip
          version = version.to_s.strip
          raise Error, "Executor #{kind} capability name must not be empty" if name.empty?
          raise Error, "Executor #{kind} capability #{name.inspect} must declare a version" if version.empty?

          result[name] = version
        end
      end
    end
  end
end
