require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module RunDiff
  module Github
    class PullRequestReplay
      Error = Class.new(StandardError)

      Result = Data.define(
        :delivery_id,
        :repository,
        :pull_request_number,
        :installation_id,
        :baseline_sha,
        :candidate_sha,
        :response
      )

      def initialize(
        authentication: nil,
        admission_policy: RepositoryAdmissionPolicy.new,
        pull_request_client_class: PullRequestClient,
        webhook_url: nil,
        webhook_secret: ENV["RUNDIFF_GITHUB_WEBHOOK_SECRET"],
        transport: nil,
        root: ::Rails.root
      )
        @authentication = authentication
        @admission_policy = admission_policy
        @pull_request_client_class = pull_request_client_class
        @webhook_url = webhook_url || default_webhook_url
        @webhook_secret = webhook_secret
        @transport = transport
        @root = root
      end

      def call(repository:, pull_request_number:, delivery_id: nil)
        repository = repository.to_s
        pull_request_number = Integer(pull_request_number)
        delivery_id ||= "rundiff-replay-#{SecureRandom.uuid}"

        validate_repository!(repository)
        installation = authentication.repository_installation(repository:)
        installation_id = Integer(installation.fetch("id"))
        token = authentication.installation_token(installation_id:)
        pull_request = @pull_request_client_class.new(token: token.value).fetch(
          repository:,
          number: pull_request_number
        )

        payload = build_payload(
          repository:,
          pull_request_number:,
          installation_id:,
          pull_request:
        )
        body = JSON.generate(payload)
        response = post_webhook(body:, delivery_id:)
        parsed = parse_response(response)

        Result.new(
          delivery_id:,
          repository:,
          pull_request_number:,
          installation_id:,
          baseline_sha: pull_request.dig("base", "sha"),
          candidate_sha: pull_request.dig("head", "sha"),
          response: parsed
        )
      rescue KeyError, ArgumentError, TypeError => error
        raise Error, "GitHub pull request replay could not prepare delivery: #{error.message}"
      end

      private

      def authentication
        @authentication ||= AppAuthentication.from_env(root: @root)
      end

      def validate_repository!(repository)
        unless @admission_policy.allowed?(repository)
          raise Error, "repository is not allowed by #{RepositoryAdmissionPolicy::ENV_NAME}: #{repository}"
        end

        owner, name = repository.split("/", 2)
        if owner.to_s.empty? || name.to_s.empty? || name.include?("/")
          raise Error, "repository must use owner/name form"
        end
      end

      def build_payload(repository:, pull_request_number:, installation_id:, pull_request:)
        {
          "action" => "synchronize",
          "number" => pull_request_number,
          "installation" => {
            "id" => installation_id
          },
          "repository" => {
            "full_name" => repository
          },
          "pull_request" => {
            "base" => {
              "ref" => pull_request.dig("base", "ref"),
              "sha" => pull_request.dig("base", "sha"),
              "repo" => {
                "full_name" => pull_request.dig("base", "repo", "full_name")
              }
            },
            "head" => {
              "ref" => pull_request.dig("head", "ref"),
              "sha" => pull_request.dig("head", "sha"),
              "repo" => {
                "full_name" => pull_request.dig("head", "repo", "full_name")
              }
            }
          }
        }
      end

      def post_webhook(body:, delivery_id:)
        secret = @webhook_secret.to_s
        raise Error, "RUNDIFF_GITHUB_WEBHOOK_SECRET is required" if secret.empty?

        signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
        headers = {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "pull_request",
          "X-GitHub-Delivery" => delivery_id,
          "X-Hub-Signature-256" => signature,
          "User-Agent" => "rundiff-pull-request-replay"
        }

        return @transport.call(url: @webhook_url, body:, headers:) if @transport

        uri = URI(@webhook_url)
        request = Net::HTTP::Post.new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = body

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end
      rescue URI::InvalidURIError => error
        raise Error, "invalid webhook URL: #{error.message}"
      end

      def parse_response(response)
        code = response.respond_to?(:code) ? response.code.to_i : Integer(response.fetch(:code))
        body = response.respond_to?(:body) ? response.body.to_s : response.fetch(:body).to_s

        unless code == 202
          raise Error, "control plane rejected replay delivery with HTTP #{code}"
        end

        JSON.parse(body)
      rescue JSON::ParserError => error
        raise Error, "control plane returned invalid JSON: #{error.message}"
      end

      def default_webhook_url
        configured = ENV["RUNDIFF_REPLAY_WEBHOOK_URL"].to_s
        return configured unless configured.empty?

        public_url = ENV["RUNDIFF_PUBLIC_URL"].to_s.sub(%r{/+$}, "")
        public_url = "http://127.0.0.1:3000" if public_url.empty?
        "#{public_url}/github/webhooks"
      end
    end
  end
end
