require "json"
require "net/http"
require "uri"

module RunDiff
  module Github
    class RepositoryContentClient
      Error = Class.new(StandardError)

      def initialize(token:, api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com"))
        @token = token.to_s
        @api_url = api_url.sub(%r{/+$}, "")
      end

      def fetch(repository:, path:, ref:)
        encoded_path = path.to_s.split("/").map { |segment| URI.encode_www_form_component(segment) }.join("/")
        encoded_ref = URI.encode_www_form_component(ref.to_s)
        request("/repos/#{repository}/contents/#{encoded_path}?ref=#{encoded_ref}")
      end

      private

      def request(path)
        uri = URI("#{@api_url}#{path}")
        http_request = Net::HTTP::Get.new(uri)
        http_request["Authorization"] = "Bearer #{@token}"
        http_request["Accept"] = "application/vnd.github+json"
        http_request["X-GitHub-Api-Version"] = "2022-11-28"
        http_request["User-Agent"] = "rundiff-github-app-preflight"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(http_request)
        end

        return nil if response.code.to_i == 404

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "GitHub repository content fetch failed: HTTP #{response.code}"
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => error
        raise Error, "GitHub repository content fetch returned invalid JSON: #{error.message}"
      end
    end
  end
end
