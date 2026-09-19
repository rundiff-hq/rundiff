require "test_helper"

class OnboardingControllerTest < ActionDispatch::IntegrationTest
  test "renders the configured GitHub App install path and minimal Rails contract" do
    previous_slug = ENV["RUNDIFF_GITHUB_APP_SLUG"]
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = "rundiff-development"

    get onboarding_url(installation_id: "untrusted-installation-id")

    assert_response :success
    assert_includes response.body, "https://github.com/apps/rundiff-development/installations/new"
    assert_includes response.body, "Your first Behavioral Review in three steps."
    assert_includes response.body, "Tests passed. Behavior changed."
    assert_includes response.body, "RunDiff / Behavioral Review"
    assert_includes response.body, "DATABASE_QUERY_REGRESSION"
    assert_includes response.body, "17 → 31"
    assert_includes response.body, "version: 1"
    assert_includes response.body, "path: /orders/42"
    assert_includes response.body, "PostgreSQL or SQLite"
    assert_includes response.body, "GitHub setup returned here. Continue with your repository."
    assert_includes response.body, "never treats them as proof of installation ownership"
    refute_includes response.body, "untrusted-installation-id"
  ensure
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = previous_slug
  end

  test "normal onboarding does not claim a GitHub setup return" do
    previous_slug = ENV["RUNDIFF_GITHUB_APP_SLUG"]
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = "rundiff-development"

    get onboarding_url

    assert_response :success
    refute_includes response.body, "GitHub setup returned here. Continue with your repository."
  ensure
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = previous_slug
  end

  test "setup_action alone may change guidance but never exposes installation data" do
    previous_slug = ENV["RUNDIFF_GITHUB_APP_SLUG"]
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = "rundiff-development"

    get onboarding_url(setup_action: "update")

    assert_response :success
    assert_includes response.body, "GitHub setup returned here. Continue with your repository."
    assert_includes response.body, "signed GitHub webhook and installation-scoped access"
  ensure
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = previous_slug
  end

  test "unknown setup_action does not claim a GitHub setup return" do
    previous_slug = ENV["RUNDIFF_GITHUB_APP_SLUG"]
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = "rundiff-development"

    get onboarding_url(setup_action: "unexpected")

    assert_response :success
    refute_includes response.body, "GitHub setup returned here. Continue with your repository."
  ensure
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = previous_slug
  end

  test "uses the development App slug by default outside production" do
    previous_slug = ENV.delete("RUNDIFF_GITHUB_APP_SLUG")
    previous_environment = ENV.delete("RUNDIFF_GITHUB_APP_MANIFEST_ENV")

    get onboarding_url

    assert_response :success
    assert_includes response.body, "https://github.com/apps/rundiff-development/installations/new"
  ensure
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = previous_slug
    ENV["RUNDIFF_GITHUB_APP_MANIFEST_ENV"] = previous_environment
  end

  test "rejects an invalid configured GitHub App slug" do
    previous_slug = ENV["RUNDIFF_GITHUB_APP_SLUG"]
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = "https://example.test/not-a-slug"

    get onboarding_url

    assert_response :unprocessable_entity
    assert_includes response.body, "invalid RUNDIFF_GITHUB_APP_SLUG"
  ensure
    ENV["RUNDIFF_GITHUB_APP_SLUG"] = previous_slug
  end
end
