require "test_helper"
require "base64"
require "tmpdir"

class RunDiffExecutorGitCloneAdapterTest < ActiveSupport::TestCase
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
    attr_reader :requests

    def initialize(payload)
      @payload = payload
      @requests = []
    end

    def call(execution:)
      @requests << execution
      @payload
    end
  end

  class CapabilityProvider
    attr_reader :requests

    def initialize(capability)
      @capability = capability
      @requests = []
    end

    def call(request:)
      @requests << request
      @capability
    end
  end

  test "clones through an ephemeral header capability without putting the token in git arguments" do
    command_runner = CommandRunner.new
    runner = Runner.new(result_payload)
    repository_roots = []
    adapter = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner:,
      runner_factory: lambda do |repository_root:|
        repository_roots << repository_root
        runner
      end
    )
    capability = RunDiff::Executor::RepositoryCapability.new(token: "clone-token")

    result = adapter.call(request: executor_request, repository_capability: capability)

    assert result.success?
    assert_equal result_payload, result.payload
    assert_equal [ executor_request ], runner.requests

    fetch_call = command_runner.calls.find { |call| call.fetch(:command).take(2) == %w[git fetch] }
    assert fetch_call
    refute command_runner.calls.any? { |call| call.fetch(:command).join(" ").include?("clone-token") }

    expected_basic = Base64.strict_encode64("x-access-token:clone-token")
    assert_equal "AUTHORIZATION: basic #{expected_basic}", fetch_call.fetch(:env).fetch("GIT_CONFIG_VALUE_0")
    assert_equal "0", fetch_call.fetch(:env).fetch("GIT_TERMINAL_PROMPT")
    assert_includes fetch_call.fetch(:command), "+refs/heads/main:refs/remotes/origin/rundiff-base"
    assert_includes fetch_call.fetch(:command), "+refs/pull/40/head:refs/remotes/origin/rundiff-candidate"
    refute_predicate repository_roots.fetch(0), :exist?
  end

  test "places customer repositories outside the RunDiff Rails application tree" do
    command_runner = CommandRunner.new
    runner = Runner.new(result_payload)
    repository_roots = []
    adapter = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner:,
      runner_factory: lambda do |repository_root:|
        repository_roots << repository_root
        runner
      end
    )

    result = adapter.call(
      request: executor_request,
      repository_capability: RunDiff::Executor::RepositoryCapability.new(token: "clone-token")
    )

    assert result.success?
    repository_root = repository_roots.fetch(0).expand_path
    tool_root = Rails.root.expand_path
    refute repository_root.to_s.start_with?("#{tool_root}#{File::SEPARATOR}")
    assert repository_root.to_s.start_with?(Pathname(Dir.tmpdir).expand_path.to_s)
  end

  test "rejects a workspace nested under a Rails application" do
    error = assert_raises(RunDiff::Executor::GitCloneAdapter::Error) do
      RunDiff::Executor::GitCloneAdapter.new(
        root: Rails.root,
        workspace_root: Rails.root.join("tmp", "customer-workspaces"),
        command_runner: CommandRunner.new
      )
    end

    assert_match(/workspace root .* is nested under Rails application/, error.message)
    assert_includes error.message, Rails.root.to_s
  end

  test "resolves a repository capability through an injected provider" do
    command_runner = CommandRunner.new
    runner = Runner.new(result_payload)
    capability = RunDiff::Executor::RepositoryCapability.new(token: "provider-token")
    provider = CapabilityProvider.new(capability)
    adapter = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner:,
      runner_factory: ->(repository_root:) { runner },
      repository_capability_provider: provider
    )

    result = adapter.call(request: executor_request)

    assert result.success?
    assert_equal [ executor_request ], provider.requests
    fetch_call = command_runner.calls.find { |call| call.fetch(:command).take(2) == %w[git fetch] }
    expected_basic = Base64.strict_encode64("x-access-token:provider-token")
    assert_equal "AUTHORIZATION: basic #{expected_basic}", fetch_call.fetch(:env).fetch("GIT_CONFIG_VALUE_0")
  end

  test "explicit repository capability takes precedence over the provider" do
    command_runner = CommandRunner.new
    runner = Runner.new(result_payload)
    provider = CapabilityProvider.new(RunDiff::Executor::RepositoryCapability.new(token: "provider-token"))
    adapter = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner:,
      runner_factory: ->(repository_root:) { runner },
      repository_capability_provider: provider
    )

    result = adapter.call(
      request: executor_request,
      repository_capability: RunDiff::Executor::RepositoryCapability.new(token: "explicit-token")
    )

    assert result.success?
    assert_empty provider.requests
    fetch_call = command_runner.calls.find { |call| call.fetch(:command).take(2) == %w[git fetch] }
    expected_basic = Base64.strict_encode64("x-access-token:explicit-token")
    assert_equal "AUTHORIZATION: basic #{expected_basic}", fetch_call.fetch(:env).fetch("GIT_CONFIG_VALUE_0")
  end

  test "fails closed when the repository capability is missing" do
    result = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner: CommandRunner.new
    ).call(request: executor_request)

    assert result.failure?
    assert_equal "RunDiff::Executor::GitCloneAdapter::Error", result.error_class
    assert_equal "Repository capability is required for git clone execution", result.error_message
  end

  test "fails closed for a fork until multiple repository capabilities are modeled" do
    request = RunDiff::Executor::Request.new(
      schema_version: executor_request.schema_version,
      execution_id: executor_request.execution_id,
      scenario_id: executor_request.scenario_id,
      baseline_sha: executor_request.baseline_sha,
      candidate_sha: executor_request.candidate_sha,
      attempt_number: executor_request.attempt_number,
      context: executor_request.context.merge("candidate_repository" => "someone/fork")
    )
    result = RunDiff::Executor::GitCloneAdapter.new(
      root: Rails.root,
      command_runner: CommandRunner.new
    ).call(
      request:,
      repository_capability: RunDiff::Executor::RepositoryCapability.new(token: "clone-token")
    )

    assert result.failure?
    assert_equal "Git clone executor currently supports same-repository pull requests only", result.error_message
  end

  private

  def executor_request
    @executor_request ||= RunDiff::Executor::Request.new(
      schema_version: "1",
      execution_id: "github-1234567890abcdef",
      scenario_id: "scenario",
      baseline_sha: "base-sha",
      candidate_sha: "head-sha",
      attempt_number: 1,
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 40,
        "baseline_ref" => "main",
        "candidate_ref" => "feature",
        "candidate_repository" => "rundiff/rundiff"
      }
    )
  end

  def result_payload
    { "run_id" => "run", "result" => { "decision" => "allow" } }
  end
end
