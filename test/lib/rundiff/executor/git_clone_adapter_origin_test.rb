require "test_helper"
require "base64"

class RunDiffExecutorGitCloneAdapterOriginTest < ActiveSupport::TestCase
  class CommandRunner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(env:, command:, chdir:)
      @calls << { env:, command:, chdir: }
      ""
    end
  end

  class Runner
    def call(execution:)
      { "execution_id" => execution.execution_id, "result" => { "decision" => "allow" } }
    end
  end

  test "uses a configured Git transport base URL and scopes the auth header to it" do
    command_runner = CommandRunner.new
    adapter = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner:,
      runner_factory: ->(repository_root:) { Runner.new },
      git_base_url: "http://git-origin:8080/git/"
    )

    result = adapter.call(
      request: request,
      repository_capability: RunDiff::Executor::RepositoryCapability.new(token: "lab-installation-token")
    )

    assert result.success?
    remote_call = command_runner.calls.find { |call| call.fetch(:command).take(3) == %w[git remote add] }
    assert_equal "http://git-origin:8080/git/lab-customer/rails-app.git", remote_call.fetch(:command).last

    fetch_call = command_runner.calls.find { |call| call.fetch(:command).take(2) == %w[git fetch] }
    assert_equal "http.http://git-origin:8080/git/.extraheader", fetch_call.fetch(:env).fetch("GIT_CONFIG_KEY_0")
    expected_basic = Base64.strict_encode64("x-access-token:lab-installation-token")
    assert_equal "AUTHORIZATION: basic #{expected_basic}", fetch_call.fetch(:env).fetch("GIT_CONFIG_VALUE_0")
  end

  test "rejects a non HTTP Git base URL" do
    error = assert_raises(RunDiff::Executor::GitCloneAdapter::Error) do
      RunDiff::Executor::GitCloneAdapter.new(root: Rails.root, git_base_url: "file:///tmp/repositories")
    end

    assert_equal "Git base URL must be an absolute HTTP(S) URL", error.message
  end

  private

  def request
    RunDiff::Executor::Request.new(
      schema_version: "1",
      execution_id: "github-lab-1234567890abcdef",
      scenario_id: "production-lab",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      attempt_number: 1,
      context: {
        "repository" => "lab-customer/rails-app",
        "candidate_repository" => "lab-customer/rails-app",
        "pull_request_number" => 1,
        "baseline_ref" => "main",
        "candidate_ref" => "regression"
      }
    )
  end
end
