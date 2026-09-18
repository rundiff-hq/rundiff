require "test_helper"

class GithubAppManifestsControllerTest < ActionDispatch::IntegrationTest
  test "renders the resolved development manifest registration form" do
    previous_public_url = ENV["PLYWO_PUBLIC_URL"]
    previous_environment = ENV["PLYWO_GITHUB_APP_MANIFEST_ENV"]
    ENV["PLYWO_PUBLIC_URL"] = "https://plywo-dev.example.test"
    ENV["PLYWO_GITHUB_APP_MANIFEST_ENV"] = "development"

    get github_app_register_url

    assert_response :success
    assert_includes response.body, "RunDiff Development"
    assert_includes response.body, "https://plywo-dev.example.test/github/webhooks"
    assert_includes response.body, "github.com/organizations/rundiff-hq/settings/apps/new"
  ensure
    ENV["PLYWO_PUBLIC_URL"] = previous_public_url
    ENV["PLYWO_GITHUB_APP_MANIFEST_ENV"] = previous_environment
  end
end
