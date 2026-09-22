require "json"
require "net/http"
require "uri"

module RunDiff
  module Github
    class CheckPublisher
      def initialize(token:, api_url: "https://api.github.com")
        @token = token
        @api_url = api_url.sub(%r{/+$}, "")
      end

      def upsert(repository:, head_sha:, name:, external_id:, details_url:, conclusion:, title:, summary:, annotations: [])
        existing = find_existing(repository:, head_sha:, name:, external_id:)
        output = { title:, summary: }
        output[:annotations] = annotations.first(50) unless annotations.empty?
        body = {
          name:,
          status: "completed",
          conclusion:,
          external_id:,
          details_url:,
          output:
        }

        if existing
          request(:patch, "/repos/#{repository}/check-runs/#{existing.fetch("id")}", body:)
          :updated
        else
          request(:post, "/repos/#{repository}/check-runs", body: body.merge(head_sha:))
          :created
        end
      end

      private

      def find_existing(repository:, head_sha:, name:, external_id:)
        encoded_name = URI.encode_www_form_component(name)
        response = request(
          :get,
          "/repos/#{repository}/commits/#{head_sha}/check-runs?check_name=#{encoded_name}&filter=latest"
        )
        response.fetch("check_runs", []).find do |check_run|
          check_run.fetch("name") == name && check_run["external_id"] == external_id
        end
      end

      def request(method, path, body: nil)
        uri = URI("#{@api_url}#{path}")
        request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
        http_request = request_class.new(uri)
        http_request["Authorization"] = "Bearer #{@token}"
        http_request["Accept"] = "application/vnd.github+json"
        http_request["X-GitHub-Api-Version"] = "2022-11-28"
        http_request["User-Agent"] = "rundiff-ci"
        http_request["Content-Type"] = "application/json" if body
        http_request.body = JSON.generate(body) if body

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(http_request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "GitHub check publish failed: HTTP #{response.code} #{response.body}"
        end

        response.body.empty? ? nil : JSON.parse(response.body)
      end
    end
  end
end
