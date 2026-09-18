require "json"
require "open3"
require "pathname"
require "securerandom"
require "yaml"

module RunDiff
  module Subject
    class ComposeServiceProvider
      Error = Class.new(StandardError)

      SAFE_INHERITED_ENV_KEYS = %w[
        PATH
        HOME
        TMPDIR
        LANG
        LC_ALL
        LC_CTYPE
        SSL_CERT_FILE
        SSL_CERT_DIR
      ].freeze
      ALLOWED_TOP_LEVEL_KEYS = %w[version name services].freeze
      ALLOWED_SERVICE_KEYS = %w[
        image
        command
        entrypoint
        environment
        healthcheck
        init
        read_only
        stop_grace_period
        stop_signal
        tmpfs
        user
        working_dir
      ].freeze

      CommandResult = Data.define(:stdout, :stderr, :success)
      Handle = Data.define(:project_name, :manifest_path, :container_id, :compose_service)
      Started = Data.define(:handle, :host, :port)

      class Open3CommandRunner
        def call(env:, argv:, chdir:)
          stdout, stderr, status = Open3.capture3(
            env,
            *argv,
            chdir: chdir.to_s,
            unsetenv_others: true
          )
          CommandResult.new(stdout:, stderr:, success: status.success?)
        end
      end

      def initialize(command_runner: Open3CommandRunner.new, host_env: ENV)
        @command_runner = command_runner
        @host_env = host_env
      end

      def start(root:, role:, step:)
        root = Pathname(root).realpath
        details = step.details
        name = details.fetch("name")
        manifest_path = resolve_manifest(
          root:,
          value: details.fetch("manifest"),
          service_name: name
        )
        compose_service = details.fetch("service")
        target_port = details.fetch("target_port")

        validate_manifest!(manifest_path:, compose_service:)
        validate_compose_config!(root:, manifest_path:, compose_service:)

        project_name = project_name(role:)
        container_name = "#{project_name}-#{name}"
        result = run!(
          root:,
          argv: [
            "docker", "compose",
            "-f", manifest_path.to_s,
            "--project-name", project_name,
            "run",
            "--detach",
            "--no-deps",
            "--pull", "missing",
            "--name", container_name,
            "--publish", "127.0.0.1::#{target_port}",
            compose_service
          ],
          context: "start Compose service #{name.inspect}"
        )
        container_id = result.stdout.strip
        if container_id.empty?
          raise Error, "Compose service #{name.inspect} did not return a container id"
        end

        port_result = run!(
          root:,
          argv: [ "docker", "port", container_id, "#{target_port}/tcp" ],
          context: "resolve published port for Compose service #{name.inspect}"
        )
        host, port = parse_loopback_port(port_result.stdout, service_name: name)

        Started.new(
          handle: Handle.new(
            project_name:,
            manifest_path:,
            container_id:,
            compose_service:
          ),
          host:,
          port:
        )
      rescue StandardError
        cleanup_partial(
          root: root || Pathname(root),
          project_name: project_name,
          manifest_path: manifest_path,
          container_id: container_id
        )
        raise
      end

      def diagnostics(handle)
        result = run(
          root: handle.manifest_path.dirname,
          argv: [ "docker", "logs", "--tail", "50", handle.container_id ]
        )
        content = [ result.stdout, result.stderr ].reject(&:empty?).join("\n")
        content.bytesize > 4_000 ? content.byteslice(-4_000, 4_000) : content
      rescue StandardError
        ""
      end

      def stop(handle)
        root = handle.manifest_path.dirname
        first_error = nil

        begin
          result = run(root:, argv: [ "docker", "rm", "-f", handle.container_id ])
          unless result.success
            first_error = Error.new(
              "Could not remove Compose container #{handle.container_id.inspect}: #{diagnostic(result)}"
            )
          end
        rescue StandardError => error
          first_error = error
        ensure
          begin
            result = run(
              root:,
              argv: [
                "docker", "compose",
                "-f", handle.manifest_path.to_s,
                "--project-name", handle.project_name,
                "down", "--volumes", "--remove-orphans"
              ]
            )
            unless result.success
              first_error ||= Error.new(
                "Could not tear down Compose project #{handle.project_name.inspect}: #{diagnostic(result)}"
              )
            end
          rescue StandardError => error
            first_error ||= error
          end
        end

        raise first_error if first_error
      end

      private

      def validate_manifest!(manifest_path:, compose_service:)
        payload = YAML.safe_load(
          manifest_path.read,
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false
        ) || {}
        unless payload.is_a?(Hash)
          raise Error, "Compose manifest must be a mapping"
        end

        unknown_top_level = payload.keys.map(&:to_s) - ALLOWED_TOP_LEVEL_KEYS
        unless unknown_top_level.empty?
          raise Error,
            "Compose manifest uses unsupported top-level keys: #{unknown_top_level.sort.join(", ")}"
        end

        services = payload.fetch("services") { raise Error, "Compose manifest must declare services" }
        unless services.is_a?(Hash)
          raise Error, "Compose manifest services must be a mapping"
        end

        services.each do |name, service|
          validate_manifest_service!(name.to_s, service)
        end
        unless services.key?(compose_service)
          raise Error, "Compose manifest does not declare service #{compose_service.inspect}"
        end
      rescue Psych::Exception => error
        raise Error, "Invalid Compose manifest: #{error.message}"
      end

      def validate_manifest_service!(name, service)
        unless service.is_a?(Hash)
          raise Error, "Compose service #{name.inspect} must be a mapping"
        end

        unknown_service_keys = service.keys.map(&:to_s) - ALLOWED_SERVICE_KEYS
        unless unknown_service_keys.empty?
          raise Error,
            "Compose service #{name.inspect} uses unsupported keys: " \
            "#{unknown_service_keys.sort.join(", ")}"
        end

        image = service["image"]
        unless image.is_a?(String) && !image.strip.empty?
          raise Error, "Compose service #{name.inspect} must declare an image"
        end
      end

      def validate_compose_config!(root:, manifest_path:, compose_service:)
        result = run!(
          root:,
          argv: [
            "docker", "compose",
            "-f", manifest_path.to_s,
            "config", "--format", "json"
          ],
          context: "validate Compose manifest"
        )
        payload = JSON.parse(result.stdout)
        services = payload.fetch("services")
        unless services.is_a?(Hash) && services.key?(compose_service)
          raise Error, "Resolved Compose config does not declare service #{compose_service.inspect}"
        end
      rescue JSON::ParserError, KeyError => error
        raise Error, "Invalid resolved Compose config: #{error.message}"
      end

      def resolve_manifest(root:, value:, service_name:)
        root = root.realpath
        candidate = root.join(value)
        resolved = candidate.realpath
        prefix = "#{root.to_s.chomp(File::SEPARATOR)}#{File::SEPARATOR}"

        unless resolved.to_s.start_with?(prefix) && resolved.file?
          raise Error,
            "Compose service #{service_name.inspect} manifest must resolve to a file inside the repository"
        end

        resolved
      rescue Errno::ENOENT, Errno::EACCES => error
        raise Error, "Compose service #{service_name.inspect} manifest is unavailable: #{error.message}"
      end

      def project_name(role:)
        role = role.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A[-_]+|[-_]+\z/, "")
        role = "subject" if role.empty?
        "rundiff-#{role}-#{SecureRandom.hex(6)}"
      end

      def parse_loopback_port(value, service_name:)
        endpoints = value.lines.map(&:strip).reject(&:empty?)
        endpoint = endpoints.find { |item| item.match?(/\A127\.0\.0\.1:\d+\z/) }
        unless endpoint
          raise Error,
            "Compose service #{service_name.inspect} did not publish its target port on 127.0.0.1: " \
            "#{endpoints.inspect}"
        end

        host, port = endpoint.split(":", 2)
        [ host, Integer(port, 10) ]
      rescue ArgumentError
        raise Error, "Compose service #{service_name.inspect} returned an invalid published port #{value.inspect}"
      end

      def cleanup_partial(root:, project_name:, manifest_path:, container_id:)
        run(root:, argv: [ "docker", "rm", "-f", container_id ]) if container_id
        return unless project_name && manifest_path

        run(
          root:,
          argv: [
            "docker", "compose",
            "-f", manifest_path.to_s,
            "--project-name", project_name,
            "down", "--volumes", "--remove-orphans"
          ]
        )
      rescue StandardError
        nil
      end

      def run!(root:, argv:, context:)
        result = run(root:, argv:)
        return result if result.success

        raise Error, "Could not #{context}: #{diagnostic(result)}"
      end

      def run(root:, argv:)
        @command_runner.call(
          env: safe_inherited_environment,
          argv:,
          chdir: root
        )
      end

      def diagnostic(result)
        [ result.stderr, result.stdout ].reject(&:empty?).join(" | ").strip
      end

      def safe_inherited_environment
        SAFE_INHERITED_ENV_KEYS.each_with_object({}) do |key, environment|
          value = @host_env[key]
          environment[key] = value if value
        end
      end
    end
  end
end
