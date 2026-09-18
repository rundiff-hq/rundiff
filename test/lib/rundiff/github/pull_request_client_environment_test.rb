require "test_helper"

class RunDiffGithubPullRequestClientEnvironmentTest < ActiveSupport::TestCase
  test "uses GITHUB_API_URL by default" do
    previous = ENV["GITHUB_API_URL"]
    ENV["GITHUB_API_URL"] = "http://github-emulator:4001/"

    client = RunDiff::Github::PullRequestClient.new(token: "token")

    assert_equal "http://github-emulator:4001", client.instance_variable_get(:@api_url)
  ensure
    previous.nil? ? ENV.delete("GITHUB_API_URL") : ENV["GITHUB_API_URL"] = previous
  end

  test "explicit api_url wins over the environment" do
    previous = ENV["GITHUB_API_URL"]
    ENV["GITHUB_API_URL"] = "http://github-emulator:4001"

    client = RunDiff::Github::PullRequestClient.new(token: "token", api_url: "https://github.example/api/v3/")

    assert_equal "https://github.example/api/v3", client.instance_variable_get(:@api_url)
  ensure
    previous.nil? ? ENV.delete("GITHUB_API_URL") : ENV["GITHUB_API_URL"] = previous
  end
end
