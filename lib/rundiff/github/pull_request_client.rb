require "json"
require "net/http"
require "uri"

module RunDiff
  module Github
    class PullRequestClient
      Error = Class.new(StandardError)

      def initialize(token:, api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com"))
        @token = token
        @api_url = api_url.sub(%r{/+$}, "")
      end

      def fetch(repository:, number:)
        request(:get, "/repos/#{repository}/pulls/#{Integer(number)}")
      end

      private

      def request(method, path)
        uri = URI("#{@api_url}#{path}")
        request_class = { get: Net::HTTP::Get }.fetch(method)
        http_request = request_class.new(uri)
        http_request["Authorization"] = "Bearer #{@token}"
        http_request["Accept"] = "application/vnd.github+json"
        http_request["X-GitHub-Api-Version"] = "2022-11-28"
        http_request["User-Agent"] = "rundiff-github-app"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(http_request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "GitHub pull request fetch failed: HTTP #{response.code} #{response.body}"
        end

        JSON.parse(response.body)
      end
    end
  end
end
