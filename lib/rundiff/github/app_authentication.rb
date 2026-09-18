require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module RunDiff
  module Github
    class AppAuthentication
      Error = Class.new(StandardError)
      Token = Data.define(:value, :expires_at)

      def self.from_env(root: Dir.pwd)
        private_key_path = File.expand_path(ENV.fetch("RUNDIFF_GITHUB_PRIVATE_KEY_PATH"), root.to_s)

        new(
          app_id: ENV.fetch("RUNDIFF_GITHUB_APP_ID"),
          private_key_path:,
          api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com")
        )
      end

      def initialize(app_id:, private_key_path:, api_url: "https://api.github.com", clock: -> { Time.now.utc })
        @app_id = app_id.to_s
        @private_key_path = private_key_path
        @api_url = api_url.sub(%r{/+$}, "")
        @clock = clock
      end

      def app
        request(:get, "/app", authorization: "Bearer #{app_jwt}")
      end

      def webhook_configuration
        request(:get, "/app/hook/config", authorization: "Bearer #{app_jwt}")
      end

      def installation_token(installation_id:, repositories: nil, permissions: nil)
        body = {}
        body[:repositories] = Array(repositories) if repositories
        body[:permissions] = permissions if permissions

        response = request(
          :post,
          "/app/installations/#{Integer(installation_id)}/access_tokens",
          authorization: "Bearer #{app_jwt}",
          body:
        )

        Token.new(
          value: response.fetch("token"),
          expires_at: Time.iso8601(response.fetch("expires_at"))
        )
      end

      def sync_webhook!(url:, secret:)
        request(
          :patch,
          "/app/hook/config",
          authorization: "Bearer #{app_jwt}",
          body: {
            url:,
            content_type: "json",
            secret:,
            insecure_ssl: "0"
          }
        )
      end

      private

      def app_jwt
        now = @clock.call.to_i
        header = { alg: "RS256", typ: "JWT" }
        payload = { iat: now - 60, exp: now + (9 * 60), iss: @app_id }
        signing_input = [ header, payload ].map { |part| base64url(JSON.generate(part)) }.join(".")
        signature = private_key.sign(OpenSSL::Digest::SHA256.new, signing_input)

        "#{signing_input}.#{base64url(signature)}"
      end

      def private_key
        @private_key ||= OpenSSL::PKey::RSA.new(File.read(@private_key_path))
      rescue Errno::ENOENT, OpenSSL::PKey::RSAError => error
        raise Error, "GitHub App private key could not be loaded: #{error.message}"
      end

      def base64url(value)
        Base64.urlsafe_encode64(value, padding: false)
      end

      def request(method, path, authorization:, body: {})
        uri = URI("#{@api_url}#{path}")
        request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
        http_request = request_class.new(uri)
        http_request["Authorization"] = authorization
        http_request["Accept"] = "application/vnd.github+json"
        http_request["X-GitHub-Api-Version"] = "2022-11-28"
        http_request["User-Agent"] = "rundiff-github-app"
        unless method == :get
          http_request["Content-Type"] = "application/json"
          http_request.body = JSON.generate(body)
        end

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(http_request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "GitHub App authentication failed: HTTP #{response.code} #{response.body}"
        end

        JSON.parse(response.body)
      end
    end
  end
end
