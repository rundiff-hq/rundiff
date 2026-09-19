require "test_helper"

class RunDiffGithubAppConfigurationVerifierTest < ActiveSupport::TestCase
  FakeAuthentication = Struct.new(:app_payload, :webhook_payload) do
    def app
      app_payload
    end

    def webhook_configuration
      webhook_payload
    end
  end

  test "accepts the canonical production GitHub App contract" do
    verifier = build_verifier(
      app: canonical_app,
      webhook: canonical_webhook
    )

    result = verifier.call

    assert_equal "RunDiff", result.fetch("name")
    assert_equal "rundiff", result.fetch("slug")
    assert_equal "rundiff-hq", result.fetch("owner")
    assert_equal "https://app.rundiff.com/github/webhooks", result.fetch("webhook_url")
    assert_equal %w[check_run pull_request], result.fetch("events")
    refute_includes JSON.generate(result), "secret"
  end

  test "committed production manifest matches the verified minimal contract" do
    manifest = JSON.parse(Rails.root.join(".github/app-manifest.json").read)

    assert_equal(
      RunDiff::Github::AppConfigurationVerifier::REQUIRED_PERMISSIONS,
      manifest.fetch("default_permissions")
    )
    assert_equal(
      RunDiff::Github::AppConfigurationVerifier::REQUIRED_EVENTS.sort,
      manifest.fetch("default_events").sort
    )
    refute manifest.fetch("default_permissions").key?("issues")
  end

  test "allows GitHub implicit metadata read but rejects extra permissions" do
    app = canonical_app
    app["permissions"] = app.fetch("permissions").merge(
      "metadata" => "read",
      "issues" => "write"
    )

    error = assert_raises(RunDiff::Github::AppConfigurationVerifier::Error) do
      build_verifier(app:, webhook: canonical_webhook).call
    end

    assert_includes error.message, "unexpected permissions"
    assert_includes error.message, "issues"
  end

  test "fails when the App identity is still not canonical" do
    app = canonical_app.merge(
      "name" => "Old Name",
      "slug" => "old-slug",
      "owner" => { "login" => "other-owner" }
    )

    error = assert_raises(RunDiff::Github::AppConfigurationVerifier::Error) do
      build_verifier(app:, webhook: canonical_webhook).call
    end

    assert_includes error.message, "name="
    assert_includes error.message, "slug="
    assert_includes error.message, "owner="
  end

  test "fails when webhook URL, content type, or TLS mode is wrong" do
    webhook = canonical_webhook.merge(
      "url" => "https://wrong.example.test/github/webhooks",
      "content_type" => "form",
      "insecure_ssl" => "1"
    )

    error = assert_raises(RunDiff::Github::AppConfigurationVerifier::Error) do
      build_verifier(app: canonical_app, webhook:).call
    end

    assert_includes error.message, "webhook.url"
    assert_includes error.message, "webhook.content_type"
    assert_includes error.message, "webhook.insecure_ssl"
  end

  test "fails when subscribed events differ from the minimal contract" do
    app = canonical_app.merge("events" => %w[check_run pull_request push])

    error = assert_raises(RunDiff::Github::AppConfigurationVerifier::Error) do
      build_verifier(app:, webhook: canonical_webhook).call
    end

    assert_includes error.message, "events="
    assert_includes error.message, "push"
  end

  private

  def build_verifier(app:, webhook:)
    RunDiff::Github::AppConfigurationVerifier.new(
      authentication: FakeAuthentication.new(app, webhook),
      expected_slug: "rundiff",
      expected_name: "RunDiff",
      expected_owner: "rundiff-hq",
      expected_external_url: "https://github.com/rundiff-hq/rundiff",
      expected_webhook_url: "https://app.rundiff.com/github/webhooks"
    )
  end

  def canonical_app
    {
      "name" => "RunDiff",
      "slug" => "rundiff",
      "owner" => { "login" => "rundiff-hq" },
      "external_url" => "https://github.com/rundiff-hq/rundiff",
      "html_url" => "https://github.com/apps/rundiff",
      "permissions" => {
        "checks" => "write",
        "contents" => "read",
        "pull_requests" => "write",
        "metadata" => "read"
      },
      "events" => %w[pull_request check_run]
    }
  end

  def canonical_webhook
    {
      "url" => "https://app.rundiff.com/github/webhooks",
      "content_type" => "json",
      "insecure_ssl" => "0",
      "secret" => "masked-by-github"
    }
  end
end
