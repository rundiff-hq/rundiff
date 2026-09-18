require "test_helper"

class RunDiffGithubAppManifestTest < ActiveSupport::TestCase
  test "resolves the development manifest against the public URL" do
    manifest = RunDiff::Github::AppManifest.new(
      environment: "development",
      public_url: "https://rundiff-dev.example.test/"
    ).to_h

    assert_equal "RunDiff Development", manifest.fetch("name")
    assert_equal "https://rundiff-dev.example.test/github/webhooks", manifest.dig("hook_attributes", "url")
    assert_equal "https://rundiff-dev.example.test/github/app/manifest/callback", manifest.fetch("redirect_url")
    assert_equal "https://rundiff-dev.example.test/onboarding", manifest.fetch("setup_url")
    assert manifest.fetch("setup_on_update")
    assert_not manifest.fetch("public")
    assert_equal "write", manifest.dig("default_permissions", "checks")
    assert_equal "read", manifest.dig("default_permissions", "contents")
    assert_equal "write", manifest.dig("default_permissions", "pull_requests")
  end

  test "resolves the staging manifest" do
    manifest = RunDiff::Github::AppManifest.new(
      environment: "staging",
      public_url: "https://rundiff-staging.example.test"
    ).to_h

    assert_equal "RunDiff Staging", manifest.fetch("name")
    assert_equal "https://rundiff-staging.example.test/github/webhooks", manifest.dig("hook_attributes", "url")
    assert_equal "https://rundiff-staging.example.test/github/app/manifest/callback", manifest.fetch("redirect_url")
    assert_equal "https://rundiff-staging.example.test/onboarding", manifest.fetch("setup_url")
    assert manifest.fetch("setup_on_update")
    assert_not manifest.fetch("public")
  end

  test "resolves the public production manifest" do
    manifest = RunDiff::Github::AppManifest.new(
      environment: "production",
      public_url: "https://rundiff.example.test"
    ).to_h

    assert_equal "RunDiff", manifest.fetch("name")
    assert_equal "https://rundiff.example.test/github/webhooks", manifest.dig("hook_attributes", "url")
    assert_equal "https://rundiff.example.test/onboarding", manifest.fetch("setup_url")
    assert manifest.fetch("setup_on_update")
    assert manifest.fetch("public")
  end

  test "rejects a non HTTPS public URL" do
    error = assert_raises(ArgumentError) do
      RunDiff::Github::AppManifest.new(
        environment: "development",
        public_url: "http://localhost:3000"
      )
    end

    assert_match(/HTTPS origin/, error.message)
  end
end
