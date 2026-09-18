require "test_helper"

class RunDiffGithubAppAuthenticationEnvironmentTest < ActiveSupport::TestCase
  test "from_env honors the GitHub API base URL" do
    previous = {
      "RUNDIFF_GITHUB_PRIVATE_KEY_PATH" => ENV["RUNDIFF_GITHUB_PRIVATE_KEY_PATH"],
      "RUNDIFF_GITHUB_APP_ID" => ENV["RUNDIFF_GITHUB_APP_ID"],
      "GITHUB_API_URL" => ENV["GITHUB_API_URL"]
    }
    ENV["RUNDIFF_GITHUB_PRIVATE_KEY_PATH"] = "tmp/lab-app.pem"
    ENV["RUNDIFF_GITHUB_APP_ID"] = "12345"
    ENV["GITHUB_API_URL"] = "http://github-emulator:4001"

    authentication = RunDiff::Github::AppAuthentication.from_env(root: "/srv/rundiff")

    assert_equal "12345", authentication.instance_variable_get(:@app_id)
    assert_equal "/srv/rundiff/tmp/lab-app.pem", authentication.instance_variable_get(:@private_key_path)
    assert_equal "http://github-emulator:4001", authentication.instance_variable_get(:@api_url)
  ensure
    previous&.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end
end
