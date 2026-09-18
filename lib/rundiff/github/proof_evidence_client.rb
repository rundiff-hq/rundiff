require "json"
require "net/http"
require "uri"

module RunDiff
  module Github
    class ProofEvidenceClient
      Error = Class.new(StandardError)

      def initialize(token:, api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com"))
        @token = token.to_s
        @api_url = api_url.sub(%r{/+$}, "")
      end

      def pull_request(repository:, number:)
        request("/repos/#{repository}/pulls/#{Integer(number)}")
      end

      def check_runs(repository:, head_sha:, name:)
        encoded_name = URI.encode_www_form_component(name)
        payload = request(
          "/repos/#{repository}/commits/#{head_sha}/check-runs?check_name=#{encoded_name}&filter=latest&per_page=100"
        )

        payload.fetch("check_runs", []).select { |check_run| check_run["name"] == name }
      end

      def comments(repository:, number:)
        request("/repos/#{repository}/issues/#{Integer(number)}/comments?per_page=100")
      end

      private

      def request(path)
        uri = URI("#{@api_url}#{path}")
        http_request = Net::HTTP::Get.new(uri)
        http_request["Authorization"] = "Bearer #{@token}"
        http_request["Accept"] = "application/vnd.github+json"
        http_request["X-GitHub-Api-Version"] = "2022-11-28"
        http_request["User-Agent"] = "rundiff-production-proof"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(http_request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "GitHub proof evidence fetch failed: HTTP #{response.code} #{response.body}"
        end

        JSON.parse(response.body)
      end
    end
  end
end
