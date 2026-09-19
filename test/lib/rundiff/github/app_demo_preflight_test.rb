require "test_helper"

class RunDiffGithubAppDemoPreflightTest < ActiveSupport::TestCase
  class FakeAuthentication
    attr_reader :calls

    def initialize
      @calls = []
    end

    def app
      calls << :app
      { "name" => "RunDiff", "slug" => "rundiff" }
    end

    def repository_installation(repository:)
      calls << [ :repository_installation, repository ]
      { "id" => 77 }
    end

    def installation_token(installation_id:, repositories:, permissions:)
      calls << [ :installation_token, installation_id, repositories, permissions ]
      RunDiff::Github::AppAuthentication::Token.new(
        value: "scoped-token",
        expires_at: Time.utc(2026, 9, 19, 13, 0, 0)
      )
    end
  end

  class AllowPolicy
    def allowed?(_repository)
      true
    end
  end

  class DenyPolicy
    def allowed?(_repository)
      false
    end
  end

  class FakePullRequestClient
    class << self
      attr_accessor :payloads, :token
    end

    def initialize(token:)
      self.class.token = token
    end

    def fetch(repository:, number:)
      self.class.payloads.fetch([ repository, number ])
    end
  end

  class FakeContentClient
    class << self
      attr_accessor :files, :token
    end

    def initialize(token:)
      self.class.token = token
    end

    def fetch(repository:, path:, ref:)
      self.class.files[[ repository, path, ref ]]
    end
  end

  setup do
    repository = "rundiff-hq/customer-rails-sandbox"
    FakePullRequestClient.payloads = {
      [ repository, 4 ] => pull_request(repository:, head: "regression-sha"),
      [ repository, 5 ] => pull_request(repository:, head: "neutral-sha")
    }
    FakeContentClient.files = {
      [ repository, "rundiff.yml", "base-sha" ] => nil,
      [ repository, "rundiff.yml", "regression-sha" ] => { "type" => "file" },
      [ repository, "rundiff.yml", "neutral-sha" ] => { "type" => "file" }
    }
  end

  test "verifies installed App, remote executor, common baseline, and candidate-only config" do
    authentication = FakeAuthentication.new
    env = {
      "RUNDIFF_EXECUTOR" => "remote",
      "RUNDIFF_GITHUB_APP_CHECK_NAME" => "RunDiff / Behavioral Review"
    }

    result = RunDiff::Github::AppDemoPreflight.new(
      authentication:,
      admission_policy: AllowPolicy.new,
      pull_request_client_class: FakePullRequestClient,
      content_client_class: FakeContentClient,
      env:
    ).call(
      repository: "rundiff-hq/customer-rails-sandbox",
      regression_pr: 4,
      neutral_pr: 5
    )

    assert_equal "RunDiff", result.app_name
    assert_equal "rundiff", result.app_slug
    assert_equal 77, result.installation_id
    assert_equal "base-sha", result.baseline_sha
    assert_equal "regression-sha", result.regression_sha
    assert_equal "neutral-sha", result.neutral_sha
    assert_equal "remote", result.executor_mode
    assert_equal "RunDiff / Behavioral Review", result.check_name
    assert_equal "scoped-token", FakePullRequestClient.token
    assert_equal "scoped-token", FakeContentClient.token
    assert_includes authentication.calls, [
      :installation_token,
      77,
      [ "customer-rails-sandbox" ],
      { contents: "read", pull_requests: "read" }
    ]
  end

  test "fails closed when the repository is not admitted" do
    error = assert_raises(RunDiff::Github::AppDemoPreflight::Error) do
      RunDiff::Github::AppDemoPreflight.new(
        authentication: FakeAuthentication.new,
        admission_policy: DenyPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        content_client_class: FakeContentClient,
        env: { "RUNDIFF_EXECUTOR" => "remote" }
      ).call(
        repository: "other/repository",
        regression_pr: 4,
        neutral_pr: 5
      )
    end

    assert_includes error.message, RunDiff::Github::RepositoryAdmissionPolicy::ENV_NAME
  end

  test "requires the remote executor boundary" do
    error = assert_raises(RunDiff::Github::AppDemoPreflight::Error) do
      RunDiff::Github::AppDemoPreflight.new(
        authentication: FakeAuthentication.new,
        admission_policy: AllowPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        content_client_class: FakeContentClient,
        env: { "RUNDIFF_EXECUTOR" => "git_clone" }
      ).call(
        repository: "rundiff-hq/customer-rails-sandbox",
        regression_pr: 4,
        neutral_pr: 5
      )
    end

    assert_includes error.message, "must be remote"
  end

  test "requires rundiff.yml to be candidate-only" do
    repository = "rundiff-hq/customer-rails-sandbox"
    FakeContentClient.files[[ repository, "rundiff.yml", "base-sha" ]] = { "type" => "file" }

    error = assert_raises(RunDiff::Github::AppDemoPreflight::Error) do
      RunDiff::Github::AppDemoPreflight.new(
        authentication: FakeAuthentication.new,
        admission_policy: AllowPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        content_client_class: FakeContentClient,
        env: { "RUNDIFF_EXECUTOR" => "remote" }
      ).call(
        repository:,
        regression_pr: 4,
        neutral_pr: 5
      )
    end

    assert_includes error.message, "baseline"
    assert_includes error.message, "must not contain rundiff.yml"
  end

  test "requires both demo PRs to share one baseline" do
    repository = "rundiff-hq/customer-rails-sandbox"
    FakePullRequestClient.payloads[[ repository, 5 ]] =
      pull_request(repository:, head: "neutral-sha", base: "other-base")

    error = assert_raises(RunDiff::Github::AppDemoPreflight::Error) do
      RunDiff::Github::AppDemoPreflight.new(
        authentication: FakeAuthentication.new,
        admission_policy: AllowPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        content_client_class: FakeContentClient,
        env: { "RUNDIFF_EXECUTOR" => "remote" }
      ).call(
        repository:,
        regression_pr: 4,
        neutral_pr: 5
      )
    end

    assert_includes error.message, "must share the same baseline"
  end

  private

  def pull_request(repository:, head:, base: "base-sha")
    {
      "state" => "open",
      "base" => {
        "sha" => base,
        "ref" => "main",
        "repo" => { "full_name" => repository }
      },
      "head" => {
        "sha" => head,
        "ref" => "demo",
        "repo" => { "full_name" => repository }
      }
    }
  end
end
