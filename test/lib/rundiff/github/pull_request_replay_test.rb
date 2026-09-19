require "test_helper"
require "json"
require "openssl"

class RunDiffGithubPullRequestReplayTest < ActiveSupport::TestCase
  class FakeAuthentication
    attr_reader :calls

    def initialize
      @calls = []
    end

    def repository_installation(repository:)
      @calls << [ :repository_installation, repository ]
      { "id" => 42 }
    end

    def installation_token(installation_id:)
      @calls << [ :installation_token, installation_id ]
      RunDiff::Github::AppAuthentication::Token.new(
        value: "installation-token",
        expires_at: Time.utc(2026, 9, 19, 13, 0, 0)
      )
    end
  end

  class FakePullRequestClient
    class << self
      attr_accessor :last_token, :calls
    end

    def initialize(token:)
      self.class.last_token = token
      self.class.calls = []
    end

    def fetch(repository:, number:)
      self.class.calls << [ repository, number ]
      {
        "base" => {
          "ref" => "main",
          "sha" => "base-sha",
          "repo" => { "full_name" => repository }
        },
        "head" => {
          "ref" => "demo/rundiff-block",
          "sha" => "head-sha",
          "repo" => { "full_name" => repository }
        }
      }
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

  test "replays a current PR as a correctly signed webhook delivery" do
    authentication = FakeAuthentication.new
    request = nil
    transport = lambda do |url:, body:, headers:|
      request = { url:, body:, headers: }
      {
        code: 202,
        body: JSON.generate(
          ok: true,
          event: "pull_request",
          delivery: headers.fetch("X-GitHub-Delivery"),
          delivery_status: "accepted"
        )
      }
    end

    result = RunDiff::Github::PullRequestReplay.new(
      authentication:,
      admission_policy: AllowPolicy.new,
      pull_request_client_class: FakePullRequestClient,
      webhook_url: "https://app.rundiff.test/github/webhooks",
      webhook_secret: "webhook-secret",
      transport:
    ).call(
      repository: "rundiff-hq/customer-rails-sandbox",
      pull_request_number: 4,
      delivery_id: "replay-4"
    )

    assert_equal "replay-4", result.delivery_id
    assert_equal 42, result.installation_id
    assert_equal "base-sha", result.baseline_sha
    assert_equal "head-sha", result.candidate_sha
    assert_equal [ [ :repository_installation, "rundiff-hq/customer-rails-sandbox" ], [ :installation_token, 42 ] ],
      authentication.calls
    assert_equal "installation-token", FakePullRequestClient.last_token
    assert_equal [ [ "rundiff-hq/customer-rails-sandbox", 4 ] ], FakePullRequestClient.calls

    assert_equal "https://app.rundiff.test/github/webhooks", request.fetch(:url)
    headers = request.fetch(:headers)
    assert_equal "pull_request", headers.fetch("X-GitHub-Event")
    assert_equal "replay-4", headers.fetch("X-GitHub-Delivery")
    assert RunDiff::Github::WebhookVerifier.new.valid?(
      payload: request.fetch(:body),
      signature: headers.fetch("X-Hub-Signature-256"),
      secret: "webhook-secret"
    )

    payload = JSON.parse(request.fetch(:body))
    assert_equal "synchronize", payload.fetch("action")
    assert_equal 4, payload.fetch("number")
    assert_equal 42, payload.dig("installation", "id")
    assert_equal "rundiff-hq/customer-rails-sandbox", payload.dig("repository", "full_name")
    assert_equal "base-sha", payload.dig("pull_request", "base", "sha")
    assert_equal "head-sha", payload.dig("pull_request", "head", "sha")
  end

  test "does not bypass the repository admission policy" do
    authentication = FakeAuthentication.new
    transport_called = false

    error = assert_raises(RunDiff::Github::PullRequestReplay::Error) do
      RunDiff::Github::PullRequestReplay.new(
        authentication:,
        admission_policy: DenyPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        webhook_url: "https://app.rundiff.test/github/webhooks",
        webhook_secret: "webhook-secret",
        transport: ->(**) { transport_called = true }
      ).call(
        repository: "other/repository",
        pull_request_number: 4
      )
    end

    assert_includes error.message, "not allowed"
    assert_empty authentication.calls
    refute transport_called
  end

  test "fails before transport when the webhook secret is missing" do
    error = assert_raises(RunDiff::Github::PullRequestReplay::Error) do
      RunDiff::Github::PullRequestReplay.new(
        authentication: FakeAuthentication.new,
        admission_policy: AllowPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        webhook_url: "https://app.rundiff.test/github/webhooks",
        webhook_secret: "",
        transport: ->(**) { flunk "transport must not run" }
      ).call(
        repository: "rundiff-hq/customer-rails-sandbox",
        pull_request_number: 4
      )
    end

    assert_includes error.message, "RUNDIFF_GITHUB_WEBHOOK_SECRET is required"
  end

  test "reports a rejected control-plane delivery without leaking response body" do
    error = assert_raises(RunDiff::Github::PullRequestReplay::Error) do
      RunDiff::Github::PullRequestReplay.new(
        authentication: FakeAuthentication.new,
        admission_policy: AllowPolicy.new,
        pull_request_client_class: FakePullRequestClient,
        webhook_url: "https://app.rundiff.test/github/webhooks",
        webhook_secret: "webhook-secret",
        transport: ->(**) { { code: 401, body: "sensitive-body" } }
      ).call(
        repository: "rundiff-hq/customer-rails-sandbox",
        pull_request_number: 4
      )
    end

    assert_includes error.message, "HTTP 401"
    refute_includes error.message, "sensitive-body"
  end
end
