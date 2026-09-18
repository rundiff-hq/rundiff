require "test_helper"

class GithubAppManifestsControllerTest < ActionDispatch::IntegrationTest
  test "renders the resolved development manifest registration form" do
    previous_public_url = ENV["RUNDIFF_PUBLIC_URL"]
    previous_environment = ENV["RUNDIFF_GITHUB_APP_MANIFEST_ENV"]
    ENV["RUNDIFF_PUBLIC_URL"] = "https://rundiff-dev.example.test"
    ENV["RUNDIFF_GITHUB_APP_MANIFEST_ENV"] = "development"

    get github_app_register_url

    assert_response :success
    assert_includes response.body, "RunDiff Development"
    assert_includes response.body, "https://rundiff-dev.example.test/github/webhooks"
    assert_includes response.body, "github.com/organizations/rundiff-hq/settings/apps/new"
  ensure
    ENV["RUNDIFF_PUBLIC_URL"] = previous_public_url
    ENV["RUNDIFF_GITHUB_APP_MANIFEST_ENV"] = previous_environment
  end
end
