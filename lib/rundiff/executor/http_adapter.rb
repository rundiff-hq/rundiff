require "json"
require "net/http"
require "uri"

module RunDiff
  module Executor
    class HttpAdapter
      Error = Class.new(StandardError)
      Response = Data.define(:status, :body)

      DEFAULT_OPEN_TIMEOUT_SECONDS = 5
      DEFAULT_READ_TIMEOUT_SECONDS = 2_100
      DEFAULT_CONTROL_READ_TIMEOUT_SECONDS = 30

      class NetHttpTransport
        def call(uri:, headers:, body:, open_timeout:, read_timeout:)
          request = Net::HTTP::Post.new(uri)
          headers.each { |name, value| request[name] = value }
          request.body = body

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout:,
            read_timeout:
          ) do |http|
            http.request(request)
          end

          Response.new(status: Integer(response.code), body: response.body.to_s)
        end
      end

      def initialize(
        url:,
        token:,
        open_timeout: DEFAULT_OPEN_TIMEOUT_SECONDS,
        read_timeout: DEFAULT_READ_TIMEOUT_SECONDS,
        transport: NetHttpTransport.new,
        repository_capability_provider: nil
      )
        @uri = URI.parse(url)
        @token = token.to_s
        @open_timeout = Integer(open_timeout)
        @read_timeout = Integer(read_timeout)
        @transport = transport
        @repository_capability_provider = repository_capability_provider

        validate_configuration!
      end

      def call(request:)
        repository_capability = @repository_capability_provider&.call(request:)
        response = @transport.call(
          uri: @uri,
          headers: execution_headers(request:, repository_capability:),
          body: JSON.generate(request.to_h),
          open_timeout: @open_timeout,
          read_timeout: @read_timeout
        )

        unless response.status.between?(200, 299)
          raise Error, "Remote executor returned HTTP #{response.status}"
        end

        payload = JSON.parse(response.body)
        raise Error, "Remote executor result must be a JSON object" unless payload.is_a?(Hash)

        Result.from_h(payload)
      rescue JSON::ParserError => error
        raise Error, "Remote executor returned invalid JSON: #{error.message}"
      rescue KeyError, ArgumentError => error
        raise Error, "Remote executor returned an invalid result: #{error.message}"
      end

      def cancel(execution_id:, attempt_number:, reason: "control_plane_cancelled")
        response = @transport.call(
          uri: cancellation_uri(execution_id:, attempt_number:),
          headers: control_headers,
          body: JSON.generate("reason" => reason.to_s),
          open_timeout: @open_timeout,
          read_timeout: control_read_timeout
        )

        unless response.status.between?(200, 299)
          raise Error, "Remote executor cancellation returned HTTP #{response.status}"
        end

        true
      end

      private

      def validate_configuration!
        raise Error, "Remote executor URL must use http or https" unless %w[http https].include?(@uri.scheme)
        raise Error, "Remote executor URL must include a host" if @uri.host.to_s.empty?
        raise Error, "Remote executor token is required" if @token.empty?
        raise Error, "Remote executor open timeout must be positive" unless @open_timeout.positive?
        raise Error, "Remote executor read timeout must be positive" unless @read_timeout.positive?
      end

      def execution_headers(request:, repository_capability:)
        headers = control_headers.merge(
          "Idempotency-Key" => "#{request.execution_id}:#{request.attempt_number}"
        )
        if repository_capability
          headers[RepositoryCapability::HEADER] = repository_capability.authorization_header
        end
        headers
      end

      def control_headers
        {
          "Accept" => "application/json",
          "Authorization" => "Bearer #{@token}",
          "Content-Type" => "application/json"
        }
      end

      def control_read_timeout
        [ @read_timeout, DEFAULT_CONTROL_READ_TIMEOUT_SECONDS ].min
      end

      def cancellation_uri(execution_id:, attempt_number:)
        uri = @uri.dup
        base_path = uri.path.sub(%r{/+$}, "")
        encoded_execution_id = URI.encode_www_form_component(execution_id.to_s)
        uri.path = "#{base_path}/#{encoded_execution_id}/attempts/#{Integer(attempt_number)}/cancel"
        uri
      end
    end
  end
end
