require "json"
require "net/http"
require "uri"

module RunDiff
  module Github
    class AppManifestConverter
      class Error < StandardError; end

      def initialize(api_url: "https://api.github.com")
        @api_url = api_url.sub(%r{/+\z}, "")
      end

      def call(code:)
        raise ArgumentError, "manifest conversion code is required" if code.to_s.empty?

        uri = URI("#{@api_url}/app-manifests/#{URI.encode_www_form_component(code)}/conversions")
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28"
        request["User-Agent"] = "rundiff-github-app-bootstrap"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "GitHub App manifest conversion failed: HTTP #{response.code}"
        end

        JSON.parse(response.body)
      end
    end
  end
end
