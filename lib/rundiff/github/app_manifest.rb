require "json"
require "uri"

module RunDiff
  module Github
    class AppManifest
      PLACEHOLDER = "{{RUNDIFF_PUBLIC_URL}}"
      FILES = {
        "development" => ".github/app-manifest.development.json",
        "staging" => ".github/app-manifest.staging.json",
        "production" => ".github/app-manifest.json"
      }.freeze

      def initialize(environment:, public_url:, root: ::Rails.root)
        @environment = environment.to_s
        @public_url = normalize_public_url(public_url)
        @root = root
      end

      def to_h
        replace_placeholders(JSON.parse(path.read))
      end

      def to_json(*_args)
        JSON.generate(to_h)
      end

      def path
        @root.join(FILES.fetch(@environment) do
          raise ArgumentError, "unsupported GitHub App manifest environment: #{@environment.inspect}"
        end)
      end

      private

      def normalize_public_url(value)
        uri = URI(value.to_s)
        path = uri.path.to_s
        unless uri.is_a?(URI::HTTPS) && uri.host && (path.empty? || path == "/") && uri.query.nil? && uri.fragment.nil?
          raise ArgumentError, "RUNDIFF_PUBLIC_URL must be an HTTPS origin without a path"
        end

        value.to_s.sub(%r{/+\z}, "")
      rescue URI::InvalidURIError
        raise ArgumentError, "RUNDIFF_PUBLIC_URL must be a valid HTTPS origin"
      end

      def replace_placeholders(value)
        case value
        when Hash
          value.transform_values { |nested| replace_placeholders(nested) }
        when Array
          value.map { |nested| replace_placeholders(nested) }
        when String
          value.gsub(PLACEHOLDER, @public_url)
        else
          value
        end
      end
    end
  end
end
