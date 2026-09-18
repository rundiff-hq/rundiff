module RunDiff
  module Github
    class AppConfigurationVerifier
      Error = Class.new(StandardError)

      REQUIRED_PERMISSIONS = {
        "checks" => "write",
        "contents" => "read",
        "pull_requests" => "write"
      }.freeze
      ALLOWED_IMPLICIT_PERMISSIONS = {
        "metadata" => "read"
      }.freeze
      REQUIRED_EVENTS = %w[check_run pull_request].freeze

      def initialize(
        authentication: AppAuthentication.from_env(root: Rails.root),
        expected_slug: ENV.fetch("RUNDIFF_GITHUB_APP_SLUG"),
        expected_name: "RunDiff",
        expected_owner: "rundiff-hq",
        expected_external_url: "https://github.com/rundiff-hq/rundiff",
        expected_webhook_url: "https://app.rundiff.com/github/webhooks"
      )
        @authentication = authentication
        @expected_slug = expected_slug
        @expected_name = expected_name
        @expected_owner = expected_owner
        @expected_external_url = expected_external_url
        @expected_webhook_url = expected_webhook_url
      end

      def call
        app = @authentication.app
        webhook = @authentication.webhook_configuration
        errors = []

        compare!(errors, "name", app["name"], @expected_name)
        compare!(errors, "slug", app["slug"], @expected_slug)
        compare!(errors, "owner", app.dig("owner", "login"), @expected_owner)
        compare!(errors, "external_url", normalize_url(app["external_url"]), normalize_url(@expected_external_url))
        compare!(errors, "html_url", normalize_url(app["html_url"]), "https://github.com/apps/#{@expected_slug}")

        verify_permissions!(errors, app.fetch("permissions", {}))
        verify_events!(errors, app.fetch("events", []))

        compare!(errors, "webhook.url", normalize_url(webhook["url"]), normalize_url(@expected_webhook_url))
        compare!(errors, "webhook.content_type", webhook["content_type"], "json")
        compare!(errors, "webhook.insecure_ssl", webhook["insecure_ssl"].to_s, "0")

        raise Error, errors.join("; ") unless errors.empty?

        {
          "name" => app.fetch("name"),
          "slug" => app.fetch("slug"),
          "owner" => app.dig("owner", "login"),
          "external_url" => app["external_url"],
          "html_url" => app["html_url"],
          "permissions" => REQUIRED_PERMISSIONS,
          "events" => REQUIRED_EVENTS.sort,
          "webhook_url" => webhook.fetch("url"),
          "webhook_content_type" => webhook.fetch("content_type"),
          "webhook_tls_verification" => "enabled"
        }
      end

      private

      def compare!(errors, label, actual, expected)
        return if actual == expected

        errors << "#{label}=#{actual.inspect}, expected #{expected.inspect}"
      end

      def verify_permissions!(errors, actual)
        REQUIRED_PERMISSIONS.each do |permission, expected_level|
          compare!(errors, "permission.#{permission}", actual[permission], expected_level)
        end

        unexpected = actual.reject do |permission, level|
          REQUIRED_PERMISSIONS[permission] == level ||
            ALLOWED_IMPLICIT_PERMISSIONS[permission] == level
        end

        errors << "unexpected permissions=#{unexpected.inspect}" unless unexpected.empty?
      end

      def verify_events!(errors, actual)
        events = Array(actual).map(&:to_s).sort
        expected = REQUIRED_EVENTS.sort
        return if events == expected

        errors << "events=#{events.inspect}, expected #{expected.inspect}"
      end

      def normalize_url(value)
        value.to_s.sub(%r{/+\z}, "")
      end
    end
  end
end
