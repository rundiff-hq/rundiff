require "pathname"
require "yaml"

module RunDiff
  module Subject
    class Configuration
      Error = Class.new(StandardError)

      CURRENT_VERSION = 1
      DEFAULT_PERSISTENCE = "auto".freeze
      DEFAULT_SETUP_MODE = "auto".freeze
      DEFAULT_SERVICE_PORT_ENV = "PORT".freeze
      DEFAULT_READINESS_TIMEOUT_SECONDS = 5
      PERSISTENCE_VALUES = %w[auto postgresql sqlite].freeze
      SETUP_MODE_VALUES = %w[auto].freeze
      SERVICE_TYPE_VALUES = %w[process compose].freeze
      SERVICE_RUNTIME_VALUES = %w[ruby node].freeze
      READINESS_TYPE_VALUES = %w[http tcp].freeze
      TOP_LEVEL_KEYS = %w[version scenario subject].freeze
      SCENARIO_KEYS = %w[path].freeze
      SUBJECT_KEYS = %w[persistence setup services].freeze
      SETUP_KEYS = %w[mode].freeze
      PROCESS_SERVICE_KEYS = %w[name type runtime entrypoint args port_env url_env readiness].freeze
      COMPOSE_SERVICE_KEYS = %w[name type manifest service target_port url_scheme url_env readiness].freeze
      READINESS_KEYS = %w[type path timeout_seconds].freeze
      SERVICE_NAME_PATTERN = /\A[a-z][a-z0-9_-]*\z/
      COMPOSE_SERVICE_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
      URL_SCHEME_PATTERN = /\A[a-z][a-z0-9+.-]*\z/
      ENV_KEY_PATTERN = /\A[A-Z_][A-Z0-9_]*\z/

      Readiness = Data.define(:type, :path, :timeout_seconds)
      ProcessService = Data.define(:name, :type, :runtime, :entrypoint, :args, :port_env, :url_env, :readiness)
      Service = ProcessService
      ComposeService = Data.define(:name, :type, :manifest, :service, :target_port, :url_scheme, :url_env, :readiness)

      attr_reader :scenario_path, :persistence, :setup_mode, :services, :source_path

      def self.load(root:)
        path = Pathname(root).join("rundiff.yml")
        return new(
          scenario_path: nil,
          persistence: DEFAULT_PERSISTENCE,
          setup_mode: DEFAULT_SETUP_MODE,
          services: [],
          source_path: nil
        ) unless path.file?

        payload = YAML.safe_load(path.read, permitted_classes: [], permitted_symbols: [], aliases: false) || {}
        validate_mapping!(payload, name: path.basename.to_s, allowed_keys: TOP_LEVEL_KEYS)

        version = payload.fetch("version") { raise Error, "#{path.basename} must declare version: #{CURRENT_VERSION}" }
        raise Error, "Unsupported #{path.basename} version #{version.inspect}" unless version == CURRENT_VERSION

        scenario = payload.fetch("scenario", {}) || {}
        subject = payload.fetch("subject", {}) || {}
        setup = subject.fetch("setup", {}) || {}
        validate_mapping!(scenario, name: "scenario", allowed_keys: SCENARIO_KEYS)
        validate_mapping!(subject, name: "subject", allowed_keys: SUBJECT_KEYS)
        validate_mapping!(setup, name: "subject.setup", allowed_keys: SETUP_KEYS)

        scenario_path = scenario["path"]
        validate_scenario_path!(scenario_path)

        persistence = subject.fetch("persistence", DEFAULT_PERSISTENCE).to_s
        unless PERSISTENCE_VALUES.include?(persistence)
          raise Error, "Unsupported subject.persistence #{persistence.inspect}; expected one of #{PERSISTENCE_VALUES.join(", ")}"
        end

        setup_mode = setup.fetch("mode", DEFAULT_SETUP_MODE).to_s
        unless SETUP_MODE_VALUES.include?(setup_mode)
          raise Error, "Unsupported subject.setup.mode #{setup_mode.inspect}; expected one of #{SETUP_MODE_VALUES.join(", ")}"
        end

        services = parse_services(subject.fetch("services", []))

        new(scenario_path:, persistence:, setup_mode:, services:, source_path: path)
      rescue Psych::Exception => error
        raise Error, "Invalid #{path.basename}: #{error.message}"
      end

      def initialize(scenario_path:, persistence:, source_path:, setup_mode: DEFAULT_SETUP_MODE, services: [])
        @scenario_path = scenario_path
        @persistence = persistence
        @setup_mode = setup_mode
        @services = services.freeze
        @source_path = source_path
      end

      def capture_env
        return {} unless scenario_path

        { "RUNDIFF_SCENARIO_PATH" => scenario_path }
      end

      class << self
        private

        def parse_services(value)
          raise Error, "subject.services must be a sequence" unless value.is_a?(Array)

          services = value.each_with_index.map do |service, index|
            parse_service(service, index:)
          end

          duplicate_names = duplicates(services.map(&:name))
          unless duplicate_names.empty?
            raise Error, "Duplicate subject.services names: #{duplicate_names.join(", ")}"
          end

          duplicate_url_envs = duplicates(services.map(&:url_env))
          unless duplicate_url_envs.empty?
            raise Error, "Duplicate subject.services url_env values: #{duplicate_url_envs.join(", ")}"
          end

          services.freeze
        end

        def parse_service(value, index:)
          name = "subject.services[#{index}]"
          raise Error, "#{name} must be a mapping" unless value.is_a?(Hash)

          service_name = value.fetch("name") { raise Error, "#{name} must declare name" }.to_s
          unless SERVICE_NAME_PATTERN.match?(service_name)
            raise Error, "#{name}.name must match #{SERVICE_NAME_PATTERN.inspect}"
          end

          type = value.fetch("type") { raise Error, "#{name} must declare type" }.to_s
          unless SERVICE_TYPE_VALUES.include?(type)
            raise Error, "Unsupported #{name}.type #{type.inspect}; expected one of #{SERVICE_TYPE_VALUES.join(", ")}"
          end

          case type
          when "process"
            parse_process_service(value, name:, service_name:)
          when "compose"
            parse_compose_service(value, name:, service_name:)
          end
        end

        def parse_process_service(value, name:, service_name:)
          validate_mapping!(value, name:, allowed_keys: PROCESS_SERVICE_KEYS)

          runtime = value.fetch("runtime") { raise Error, "#{name} must declare runtime" }.to_s
          unless SERVICE_RUNTIME_VALUES.include?(runtime)
            raise Error, "Unsupported #{name}.runtime #{runtime.inspect}; expected one of #{SERVICE_RUNTIME_VALUES.join(", ")}"
          end

          entrypoint = value.fetch("entrypoint") { raise Error, "#{name} must declare entrypoint" }
          validate_relative_path!(entrypoint, name: "#{name}.entrypoint")

          args = value.fetch("args", [])
          unless args.is_a?(Array) && args.all? { |item| item.is_a?(String) }
            raise Error, "#{name}.args must be a sequence of strings"
          end

          port_env = value.fetch("port_env", DEFAULT_SERVICE_PORT_ENV).to_s
          validate_env_key!(port_env, name: "#{name}.port_env")

          url_env = value.fetch("url_env") { raise Error, "#{name} must declare url_env" }.to_s
          validate_env_key!(url_env, name: "#{name}.url_env")
          if port_env == url_env
            raise Error, "#{name}.port_env and #{name}.url_env must be different"
          end

          readiness = parse_readiness(
            value.fetch("readiness") { raise Error, "#{name} must declare readiness" },
            name: "#{name}.readiness"
          )

          ProcessService.new(
            name: service_name,
            type: "process",
            runtime:,
            entrypoint: entrypoint.dup.freeze,
            args: args.map(&:dup).freeze,
            port_env:,
            url_env:,
            readiness:
          )
        end

        def parse_compose_service(value, name:, service_name:)
          validate_mapping!(value, name:, allowed_keys: COMPOSE_SERVICE_KEYS)

          manifest = value.fetch("manifest") { raise Error, "#{name} must declare manifest" }
          validate_relative_path!(manifest, name: "#{name}.manifest")

          compose_service = value.fetch("service") { raise Error, "#{name} must declare service" }.to_s
          unless COMPOSE_SERVICE_PATTERN.match?(compose_service)
            raise Error, "#{name}.service must match #{COMPOSE_SERVICE_PATTERN.inspect}"
          end

          target_port = value.fetch("target_port") { raise Error, "#{name} must declare target_port" }
          unless target_port.is_a?(Integer) && target_port.between?(1, 65_535)
            raise Error, "#{name}.target_port must be an integer between 1 and 65535"
          end

          url_scheme = value.fetch("url_scheme") { raise Error, "#{name} must declare url_scheme" }.to_s
          unless URL_SCHEME_PATTERN.match?(url_scheme)
            raise Error, "#{name}.url_scheme must match #{URL_SCHEME_PATTERN.inspect}"
          end

          url_env = value.fetch("url_env") { raise Error, "#{name} must declare url_env" }.to_s
          validate_env_key!(url_env, name: "#{name}.url_env")

          readiness = parse_readiness(
            value.fetch("readiness") { raise Error, "#{name} must declare readiness" },
            name: "#{name}.readiness"
          )

          ComposeService.new(
            name: service_name,
            type: "compose",
            manifest: manifest.dup.freeze,
            service: compose_service,
            target_port:,
            url_scheme:,
            url_env:,
            readiness:
          )
        end

        def parse_readiness(value, name:)
          validate_mapping!(value, name:, allowed_keys: READINESS_KEYS)

          type = value.fetch("type") { raise Error, "#{name} must declare type" }.to_s
          unless READINESS_TYPE_VALUES.include?(type)
            raise Error, "Unsupported #{name}.type #{type.inspect}; expected one of #{READINESS_TYPE_VALUES.join(", ")}"
          end

          path = value["path"]
          if type == "http"
            unless path.is_a?(String) && path.start_with?("/")
              raise Error, "#{name}.path must be an absolute HTTP path starting with /"
            end
          elsif !path.nil?
            raise Error, "#{name}.path is only valid for HTTP readiness"
          end

          timeout_seconds = value.fetch("timeout_seconds", DEFAULT_READINESS_TIMEOUT_SECONDS)
          unless timeout_seconds.is_a?(Integer) && timeout_seconds.between?(1, 60)
            raise Error, "#{name}.timeout_seconds must be an integer between 1 and 60"
          end

          Readiness.new(type:, path: path&.dup&.freeze, timeout_seconds:)
        end

        def duplicates(values)
          values.group_by(&:itself).filter_map { |value, items| value if items.length > 1 }.sort
        end

        def validate_mapping!(value, name:, allowed_keys:)
          raise Error, "#{name} must be a mapping" unless value.is_a?(Hash)

          unknown_keys = value.keys.map(&:to_s) - allowed_keys
          return if unknown_keys.empty?

          raise Error, "Unknown #{name} keys: #{unknown_keys.sort.join(", ")}"
        end

        def validate_scenario_path!(path)
          return if path.nil?
          return if path.is_a?(String) && path.start_with?("/")

          raise Error, "scenario.path must be an absolute HTTP path starting with /"
        end

        def validate_relative_path!(value, name:)
          unless value.is_a?(String) && !value.empty?
            raise Error, "#{name} must be a non-empty repository-relative path"
          end

          path = Pathname(value)
          if path.absolute? || path.each_filename.any? { |component| component == ".." }
            raise Error, "#{name} must be a repository-relative path without .."
          end
        end

        def validate_env_key!(value, name:)
          return if ENV_KEY_PATTERN.match?(value)

          raise Error, "#{name} must be an uppercase environment variable name"
        end
      end
    end
  end
end
