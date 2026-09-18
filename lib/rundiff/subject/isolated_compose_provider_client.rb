require "json"
require "pathname"
require "securerandom"
require "socket"

module RunDiff
  module Subject
    class IsolatedComposeProviderClient
      Error = Class.new(StandardError)

      PROTOCOL_VERSION = 1
      PROVIDER_NAME = "compose".freeze
      ENV_SOCKET = "RUNDIFF_COMPOSE_PROVIDER_SOCKET".freeze
      MAX_MANIFEST_BYTES = 128 * 1024
      MAX_RESPONSE_BYTES = 256 * 1024

      Handle = Data.define(:id)
      Started = Data.define(:handle, :host, :port)

      attr_reader :socket_path, :provider_version

      def self.from_env(env: ENV)
        socket_path = env[ENV_SOCKET].to_s.strip
        return nil if socket_path.empty?

        new(socket_path:).tap(&:handshake!)
      end

      def initialize(socket_path:)
        @socket_path = Pathname(socket_path)
        @provider_version = nil
      end

      def handshake!
        payload = request("capabilities")
        provider = payload.fetch("provider")
        version = payload.fetch("version").to_s
        unless provider == PROVIDER_NAME && !version.empty?
          raise Error, "Unexpected service provider capability #{payload.inspect}"
        end

        @provider_version = version
        self
      rescue KeyError => error
        raise Error, "Invalid service provider capability response: #{error.message}"
      end

      def start(root:, role:, step:, execution: nil)
        root = Pathname(root).realpath
        details = step.details
        manifest = read_manifest(
          root:,
          value: details.fetch("manifest"),
          service_name: details.fetch("name")
        )
        payload = request(
          "start",
          {
            "execution_id" => execution_identifier(execution),
            "role" => role.to_s,
            "manifest" => manifest,
            "details" => details
          }
        )

        Started.new(
          handle: Handle.new(id: payload.fetch("handle_id")),
          host: payload.fetch("host"),
          port: Integer(payload.fetch("port"))
        )
      rescue KeyError, ArgumentError, TypeError => error
        raise Error, "Invalid service provider start response: #{error.message}"
      end

      def diagnostics(handle)
        request("diagnostics", { "handle_id" => handle.id }).fetch("content", "").to_s
      rescue Error
        ""
      end

      def stop(handle)
        request("stop", { "handle_id" => handle.id })
        nil
      end

      private

      def read_manifest(root:, value:, service_name:)
        candidate = root.join(value)
        resolved = candidate.realpath
        prefix = "#{root.to_s.chomp(File::SEPARATOR)}#{File::SEPARATOR}"
        unless resolved.to_s.start_with?(prefix) && resolved.file?
          raise Error,
            "Compose service #{service_name.inspect} manifest must resolve to a file inside the repository"
        end

        content = resolved.binread
        if content.bytesize > MAX_MANIFEST_BYTES
          raise Error,
            "Compose service #{service_name.inspect} manifest exceeds #{MAX_MANIFEST_BYTES} bytes"
        end

        content.force_encoding(Encoding::UTF_8)
        unless content.valid_encoding?
          raise Error, "Compose service #{service_name.inspect} manifest must be UTF-8"
        end

        content
      rescue Errno::ENOENT, Errno::EACCES => error
        raise Error, "Compose service #{service_name.inspect} manifest is unavailable: #{error.message}"
      end

      def request(operation, payload = {})
        request_id = SecureRandom.hex(12)
        socket = UNIXSocket.new(socket_path.to_s)
        socket.write(
          JSON.generate(
            "protocol_version" => PROTOCOL_VERSION,
            "request_id" => request_id,
            "operation" => operation,
            "payload" => payload
          ) + "\n"
        )
        raw = socket.gets(MAX_RESPONSE_BYTES + 1)
        raise Error, "Service provider closed the control socket without a response" unless raw
        raise Error, "Service provider response exceeds #{MAX_RESPONSE_BYTES} bytes" if raw.bytesize > MAX_RESPONSE_BYTES

        response = JSON.parse(raw)
        unless response.is_a?(Hash) && response["request_id"] == request_id
          raise Error, "Service provider returned a mismatched response"
        end
        unless response["ok"] == true
          message = response.dig("error", "message").to_s
          message = "Service provider request failed" if message.empty?
          raise Error, message
        end

        response.fetch("payload", {})
      rescue Errno::ENOENT, Errno::EACCES, Errno::ECONNREFUSED => error
        raise Error, "Isolated Compose provider is unavailable at #{socket_path}: #{error.message}"
      rescue JSON::ParserError => error
        raise Error, "Invalid service provider response: #{error.message}"
      ensure
        socket&.close
      end

      def execution_identifier(execution)
        return nil unless execution
        return execution.id.to_s if execution.respond_to?(:id) && execution.id

        nil
      end
    end
  end
end
