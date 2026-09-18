require "fileutils"
require "net/http"
require "pathname"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"
require "uri"
require_relative "execution_identity"

module RunDiff
  module Subject
    class ServiceExecutor
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
      PROCESS_START_OPERATION = "process.start".freeze
      COMPOSE_START_OPERATION = "compose.run".freeze
      HTTP_HEALTHCHECK_OPERATION = "http.wait_ready".freeze
      TCP_HEALTHCHECK_OPERATION = "tcp.wait_ready".freeze
      PROCESS_STOP_OPERATION = "process.stop".freeze
      COMPOSE_STOP_OPERATION = "compose.stop".freeze
      SUPPORTED_RUNTIMES = %w[ruby node].freeze
      STOP_TIMEOUT_SECONDS = 2
      READINESS_INTERVAL_SECONDS = 0.05

      RunningService = Data.define(
        :name,
        :kind,
        :pid,
        :handle,
        :host,
        :port,
        :url_env,
        :url,
        :stdout_path,
        :stderr_path
      )
      Session = Data.define(:services, :state_dir)
      StartResult = Data.define(:session, :env)

      def initialize(
        host_env: ENV,
        compose_provider: nil,
        execution_identity: ExecutionIdentity.new
      )
        @host_env = host_env
        @compose_provider = compose_provider
        @execution_identity = execution_identity
      end

      def start(root:, execution:, role:, env:, setup_plan:)
        steps = setup_plan&.steps_for("start_services") || []
        return StartResult.new(session: nil, env: {}) if steps.empty?

        state_dir = Pathname(Dir.mktmpdir("rundiff-services-#{role}-"))
        running = []
        capture_env = {}

        steps.each do |step|
          service = case step.operation
          when PROCESS_START_OPERATION
            start_process(
              root: Pathname(root),
              env: env.merge(capture_env),
              step:,
              state_dir:
            )
          when COMPOSE_START_OPERATION
            start_compose(
              root: Pathname(root),
              role:,
              env: env.merge(capture_env),
              step:
            )
          else
            raise Error, "Unsupported service start operation #{step.operation.inspect}"
          end

          running << service
          capture_env[service.url_env] = service.url
        end

        StartResult.new(
          session: Session.new(services: running.freeze, state_dir:),
          env: capture_env.freeze
        )
      rescue StandardError
        stop_session(Session.new(services: running.freeze, state_dir:)) if state_dir
        raise
      end

      def healthcheck(root:, execution:, role:, env:, setup_plan:, session:)
        return unless session

        services = session.services.each_with_object({}) do |service, result|
          result[service.name] = service
        end
        setup_plan.steps_for("healthcheck").each do |step|
          service_name = step.details.fetch("name")
          service = services.fetch(service_name) do
            raise Error, "Readiness references service that was not started: #{service_name}"
          end

          case step.operation
          when HTTP_HEALTHCHECK_OPERATION
            wait_until_http_ready(service:, step:, env:)
          when TCP_HEALTHCHECK_OPERATION
            wait_until_tcp_ready(service:, step:)
          else
            raise Error, "Unsupported service healthcheck operation #{step.operation.inspect}"
          end
        end
      end

      def stop(root:, execution:, role:, env:, setup_plan:, session:)
        return unless session

        validation_error = nil
        begin
          validate_stop_steps!(setup_plan:, session:)
        rescue StandardError => error
          validation_error = error
        ensure
          stop_session(session)
        end

        raise validation_error if validation_error
      end

      private

      def start_process(root:, env:, step:, state_dir:)
        details = step.details
        name = details.fetch("name")
        runtime = details.fetch("runtime")
        @execution_identity.prepare_tree(root)
        @execution_identity.prepare_directory(state_dir)
        @execution_identity.prepare_runtime_home(root)
        entrypoint = resolve_entrypoint(root:, value: details.fetch("entrypoint"), service_name: name)
        args = details.fetch("args")
        port_env = details.fetch("port_env")
        url_env = details.fetch("url_env")
        if env.key?(url_env)
          raise Error, "Service #{name.inspect} cannot overwrite capture environment #{url_env.inspect}"
        end
        unless SUPPORTED_RUNTIMES.include?(runtime)
          raise Error, "Unsupported service runtime #{runtime.inspect} for #{name.inspect}"
        end

        port = allocate_port
        host = "127.0.0.1"
        url = "http://#{host}:#{port}"
        service_env = safe_inherited_environment
          .merge(env)
          .merge(@execution_identity.environment(workspace: root))
          .merge(
            port_env => port.to_s,
            url_env => url
          )
        stdout_path = state_dir.join("#{name}.stdout.log")
        stderr_path = state_dir.join("#{name}.stderr.log")

        pid = case runtime
        when "ruby"
          Process.spawn(
            service_env,
            RbConfig.ruby,
            "--",
            entrypoint.to_s,
            *args,
            chdir: root.to_s,
            out: stdout_path.to_s,
            err: stderr_path.to_s,
            unsetenv_others: true,
            **@execution_identity.spawn_options
          )
        when "node"
          Process.spawn(
            service_env,
            "node",
            "--",
            entrypoint.to_s,
            *args,
            chdir: root.to_s,
            out: stdout_path.to_s,
            err: stderr_path.to_s,
            unsetenv_others: true,
            **@execution_identity.spawn_options
          )
        end

        RunningService.new(
          name:,
          kind: "process",
          pid:,
          handle: nil,
          host:,
          port:,
          url_env:,
          url:,
          stdout_path:,
          stderr_path:
        )
      rescue SystemCallError => error
        raise Error, "Could not start service #{name.inspect}: #{error.message}"
      end

      def start_compose(root:, role:, env:, step:)
        details = step.details
        name = details.fetch("name")
        url_env = details.fetch("url_env")
        if env.key?(url_env)
          raise Error, "Service #{name.inspect} cannot overwrite capture environment #{url_env.inspect}"
        end
        unless @compose_provider
          raise Error, "Compose service provider is unavailable for #{name.inspect}"
        end

        started = @compose_provider.start(root:, role:, step:)
        url = "#{details.fetch("url_scheme")}://#{started.host}:#{started.port}"

        RunningService.new(
          name:,
          kind: "compose",
          pid: nil,
          handle: started.handle,
          host: started.host,
          port: started.port,
          url_env:,
          url:,
          stdout_path: nil,
          stderr_path: nil
        )
      rescue ComposeServiceProvider::Error => error
        raise Error, error.message
      end

      def resolve_entrypoint(root:, value:, service_name:)
        root = root.realpath
        candidate = root.join(value)
        resolved = candidate.realpath
        prefix = "#{root.to_s.chomp(File::SEPARATOR)}#{File::SEPARATOR}"

        unless resolved.to_s.start_with?(prefix) && resolved.file?
          raise Error, "Service #{service_name.inspect} entrypoint must resolve to a file inside the repository"
        end

        resolved
      rescue Errno::ENOENT, Errno::EACCES => error
        raise Error, "Service #{service_name.inspect} entrypoint is unavailable: #{error.message}"
      end

      def wait_until_http_ready(service:, step:, env:)
        details = step.details
        path = details.fetch("path")
        timeout_seconds = details.fetch("timeout_seconds")
        url = env.fetch(details.fetch("url_env"), service.url)
        uri = URI("#{url}#{path}")
        deadline = monotonic_now + timeout_seconds
        last_error = nil

        loop do
          begin
            response = Net::HTTP.start(
              uri.host,
              uri.port,
              open_timeout: 0.5,
              read_timeout: 0.5
            ) { |http| http.get(uri.request_uri) }
            return if response.code.to_i.between?(200, 299)

            last_error = "status=#{response.code} body=#{response.body.to_s.inspect}"
          rescue SystemCallError, IOError, Timeout::Error => error
            last_error = "#{error.class}: #{error.message}"
          end

          break if monotonic_now >= deadline

          sleep READINESS_INTERVAL_SECONDS
        end

        raise_readiness_error(service:, target: uri.to_s, last_error:)
      end

      def wait_until_tcp_ready(service:, step:)
        timeout_seconds = step.details.fetch("timeout_seconds")
        deadline = monotonic_now + timeout_seconds
        last_error = nil

        loop do
          begin
            socket = TCPSocket.new(service.host, service.port)
            socket.close
            return
          rescue SystemCallError, IOError, SocketError => error
            last_error = "#{error.class}: #{error.message}"
          end

          break if monotonic_now >= deadline

          sleep READINESS_INTERVAL_SECONDS
        end

        raise_readiness_error(
          service:,
          target: "tcp://#{service.host}:#{service.port}",
          last_error:
        )
      end

      def raise_readiness_error(service:, target:, last_error:)
        raise Error,
          "Service #{service.name.inspect} failed readiness at #{target}: #{last_error}; " \
          "diagnostics=#{service_diagnostics(service).inspect}"
      end

      def validate_stop_steps!(setup_plan:, session:)
        steps = setup_plan.steps_for("stop_services")
        planned = steps.to_h do |step|
          [ step.details.fetch("name"), step.operation ]
        end
        running = session.services.to_h do |service|
          operation = service.kind == "compose" ? COMPOSE_STOP_OPERATION : PROCESS_STOP_OPERATION
          [ service.name, operation ]
        end
        return if planned == running

        raise Error,
          "Service stop plan does not match running services: " \
          "planned=#{planned.inspect} running=#{running.inspect}"
      end

      def stop_session(session)
        first_error = nil
        session.services.reverse_each do |service|
          begin
            stop_service(service)
          rescue StandardError => error
            first_error ||= error
          end
        end
        FileUtils.rm_rf(session.state_dir)
        raise first_error if first_error
      end

      def stop_service(service)
        case service.kind
        when "process"
          stop_process(service)
        when "compose"
          unless @compose_provider
            raise Error, "Compose service provider is unavailable while stopping #{service.name.inspect}"
          end
          @compose_provider.stop(service.handle)
        else
          raise Error, "Unsupported running service kind #{service.kind.inspect}"
        end
      rescue ComposeServiceProvider::Error => error
        raise Error, error.message
      end

      def stop_process(service)
        Process.kill("TERM", service.pid)
        Timeout.timeout(STOP_TIMEOUT_SECONDS) { Process.wait(service.pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      rescue Timeout::Error
        begin
          Process.kill("KILL", service.pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(service.pid)
        rescue Errno::ECHILD
          nil
        end
      end

      def service_diagnostics(service)
        case service.kind
        when "process"
          tail(service.stderr_path)
        when "compose"
          @compose_provider&.diagnostics(service.handle).to_s
        else
          ""
        end
      rescue StandardError
        ""
      end

      def allocate_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end

      def safe_inherited_environment
        SAFE_INHERITED_ENV_KEYS.each_with_object({}) do |key, environment|
          value = @host_env[key]
          environment[key] = value if value
        end
      end

      def tail(path, bytes: 2_000)
        return "" unless path&.file?

        content = path.read
        content.bytesize > bytes ? content.byteslice(-bytes, bytes) : content
      rescue StandardError
        ""
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
