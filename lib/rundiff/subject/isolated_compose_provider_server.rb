require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "socket"
require "tmpdir"
require_relative "compose_service_provider"
require_relative "isolated_compose_provider_client"
require_relative "setup_plan"

module RunDiff
  module Subject
    class IsolatedComposeProviderServer
      Error = Class.new(StandardError)

      PROTOCOL_VERSION = IsolatedComposeProviderClient::PROTOCOL_VERSION
      PROVIDER_NAME = IsolatedComposeProviderClient::PROVIDER_NAME
      PROVIDER_VERSION = "1".freeze
      MAX_REQUEST_BYTES = 256 * 1024
      START_DETAIL_KEYS = %w[
        name
        manifest
        service
        target_port
        url_scheme
        url_env
      ].freeze

      Record = Data.define(:handle, :workspace)

      attr_reader :socket_path

      def initialize(socket_path:, provider: ComposeServiceProvider.new)
        @socket_path = Pathname(socket_path)
        @provider = provider
        @records = {}
        @server = nil
      end

      def run
        prepare_socket!
        loop do
          client = @server.accept
          begin
            handle_client(client)
          ensure
            client.close
          end
        end
      ensure
        shutdown
      end

      def serve_once
        prepare_socket! unless @server
        client = @server.accept
        handle_client(client)
      ensure
        client&.close
      end

      def shutdown
        @records.keys.each { |id| stop_record(id, ignore_missing: true) }
        @server&.close
        @server = nil
        FileUtils.rm_f(socket_path)
      end

      private

      def prepare_socket!
        return if @server

        FileUtils.mkdir_p(socket_path.dirname)
        File.chmod(0o700, socket_path.dirname)
        FileUtils.rm_f(socket_path)
        @server = UNIXServer.new(socket_path.to_s)
        File.chmod(0o600, socket_path)
      end

      def handle_client(client)
        raw = client.gets(MAX_REQUEST_BYTES + 1)
        if raw.nil?
          write_error(client, nil, "Empty service provider request")
          return
        end
        if raw.bytesize > MAX_REQUEST_BYTES
          write_error(client, nil, "Service provider request exceeds #{MAX_REQUEST_BYTES} bytes")
          return
        end

        request = JSON.parse(raw)
        request_id = request["request_id"]
        validate_request!(request)
        payload = dispatch(request.fetch("operation"), request.fetch("payload", {}))
        client.write(JSON.generate("request_id" => request_id, "ok" => true, "payload" => payload) + "\n")
      rescue JSON::ParserError => error
        write_error(client, nil, "Invalid JSON request: #{error.message}")
      rescue StandardError => error
        write_error(client, request_id, error.message)
      end

      def validate_request!(request)
        unless request.is_a?(Hash)
          raise Error, "Service provider request must be a JSON object"
        end
        unless request["protocol_version"] == PROTOCOL_VERSION
          raise Error, "Unsupported service provider protocol version #{request["protocol_version"].inspect}"
        end
        unless request["request_id"].is_a?(String) && !request["request_id"].empty?
          raise Error, "Service provider request_id must be a non-empty string"
        end
        unless request["operation"].is_a?(String) && !request["operation"].empty?
          raise Error, "Service provider operation must be a non-empty string"
        end
        unless request.fetch("payload", {}).is_a?(Hash)
          raise Error, "Service provider payload must be a JSON object"
        end
      end

      def dispatch(operation, payload)
        case operation
        when "capabilities"
          { "provider" => PROVIDER_NAME, "version" => PROVIDER_VERSION }
        when "start"
          start_service(payload)
        when "diagnostics"
          diagnostics(payload)
        when "stop"
          stop_service(payload)
        else
          raise Error, "Unsupported service provider operation #{operation.inspect}"
        end
      end

      def start_service(payload)
        manifest = payload.fetch("manifest")
        details = payload.fetch("details")
        role = payload.fetch("role").to_s
        execution_id = payload["execution_id"].to_s
        unless manifest.is_a?(String) && details.is_a?(Hash)
          raise Error, "Compose provider start requires manifest text and typed details"
        end
        if role.empty? || role.bytesize > 128 || execution_id.bytesize > 128
          raise Error, "Compose provider execution ownership metadata is invalid"
        end

        unknown_details = details.keys.map(&:to_s) - START_DETAIL_KEYS
        unless unknown_details.empty?
          raise Error,
            "Compose provider start uses unsupported detail keys: #{unknown_details.sort.join(", ")}"
        end
        required_details = START_DETAIL_KEYS - [ "manifest" ]
        missing_details = required_details.reject { |key| details.key?(key) }
        unless missing_details.empty?
          raise Error,
            "Compose provider start is missing detail keys: #{missing_details.sort.join(", ")}"
        end

        workspace = Pathname(Dir.mktmpdir("rundiff-compose-authority-"))
        manifest_path = workspace.join("compose.yml")
        manifest_path.binwrite(manifest)
        File.chmod(0o600, manifest_path)

        step = SetupPlan::Step.new(
          phase: "start_services",
          operation: "compose.run",
          provenance: "explicit",
          details: details.merge("manifest" => "compose.yml")
        )
        provider_role = [ execution_id, role ].reject(&:empty?).join("-")
        started = @provider.start(root: workspace, role: provider_role, step:)
        handle_id = SecureRandom.hex(16)
        @records[handle_id] = Record.new(handle: started.handle, workspace:)

        {
          "handle_id" => handle_id,
          "host" => started.host,
          "port" => started.port,
          "provider_version" => PROVIDER_VERSION,
          "project_name" => started.handle.project_name
        }
      rescue KeyError => error
        raise Error, "Invalid Compose provider start request: #{error.message}"
      rescue StandardError
        begin
          @provider.stop(started.handle) if started
        rescue StandardError
          nil
        end
        FileUtils.rm_rf(workspace) if workspace
        raise
      end

      def diagnostics(payload)
        record = fetch_record(payload)
        { "content" => @provider.diagnostics(record.handle).to_s }
      end

      def stop_service(payload)
        handle_id = payload.fetch("handle_id")
        stop_record(handle_id)
        { "stopped" => true }
      rescue KeyError => error
        raise Error, "Invalid Compose provider stop request: #{error.message}"
      end

      def fetch_record(payload)
        handle_id = payload.fetch("handle_id")
        @records.fetch(handle_id) { raise Error, "Unknown Compose provider handle #{handle_id.inspect}" }
      rescue KeyError => error
        raise Error, "Invalid Compose provider handle request: #{error.message}"
      end

      def stop_record(handle_id, ignore_missing: false)
        record = @records.delete(handle_id)
        return if ignore_missing && !record
        raise Error, "Unknown Compose provider handle #{handle_id.inspect}" unless record

        begin
          @provider.stop(record.handle)
        ensure
          FileUtils.rm_rf(record.workspace)
        end
      end

      def write_error(client, request_id, message)
        client.write(
          JSON.generate(
            "request_id" => request_id,
            "ok" => false,
            "error" => { "message" => message.to_s }
          ) + "\n"
        )
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
