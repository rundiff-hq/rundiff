require "test_helper"

class RunDiffExecutorResolverTest < ActiveSupport::TestCase
  test "resolves the local adapter from the new executor setting" do
    adapter = RunDiff::Executor::Resolver.from_env(
      root: Rails.root,
      env: { "RUNDIFF_EXECUTOR" => "local" },
      rails_env: ActiveSupport::EnvironmentInquirer.new("test")
    )

    assert_instance_of RunDiff::Executor::LocalAdapter, adapter
  end

  test "defaults development to the authenticated git clone adapter" do
    adapter = RunDiff::Executor::Resolver.from_env(
      root: Rails.root,
      env: {},
      rails_env: ActiveSupport::EnvironmentInquirer.new("development")
    )

    assert_instance_of RunDiff::Executor::GitCloneAdapter, adapter
  end

  test "resolves the authenticated git clone adapter explicitly" do
    adapter = RunDiff::Executor::Resolver.from_env(
      root: Rails.root,
      env: { "RUNDIFF_EXECUTOR" => "git_clone" },
      rails_env: ActiveSupport::EnvironmentInquirer.new("test")
    )

    assert_instance_of RunDiff::Executor::GitCloneAdapter, adapter
  end

  test "resolves the remote HTTP adapter from explicit configuration" do
    adapter = RunDiff::Executor::Resolver.from_env(
      root: Rails.root,
      env: {
        "RUNDIFF_EXECUTOR" => "remote",
        "RUNDIFF_REMOTE_EXECUTOR_URL" => "https://executor.example.test/v1/executions",
        "RUNDIFF_REMOTE_EXECUTOR_TOKEN" => "secret",
        "RUNDIFF_REMOTE_EXECUTOR_OPEN_TIMEOUT_SECONDS" => "4",
        "RUNDIFF_REMOTE_EXECUTOR_READ_TIMEOUT_SECONDS" => "90"
      },
      rails_env: ActiveSupport::EnvironmentInquirer.new("test")
    )

    assert_instance_of RunDiff::Executor::HttpAdapter, adapter
  end

  test "requires the remote executor URL and token" do
    error = assert_raises(RunDiff::Executor::Resolver::Error) do
      RunDiff::Executor::Resolver.from_env(
        root: Rails.root,
        env: { "RUNDIFF_EXECUTOR" => "remote" },
        rails_env: ActiveSupport::EnvironmentInquirer.new("test")
      )
    end

    assert_equal "RUNDIFF_REMOTE_EXECUTOR_URL is required", error.message

    error = assert_raises(RunDiff::Executor::Resolver::Error) do
      RunDiff::Executor::Resolver.from_env(
        root: Rails.root,
        env: {
          "RUNDIFF_EXECUTOR" => "remote",
          "RUNDIFF_REMOTE_EXECUTOR_URL" => "https://executor.example.test/v1/executions"
        },
        rails_env: ActiveSupport::EnvironmentInquirer.new("test")
      )
    end

    assert_equal "RUNDIFF_REMOTE_EXECUTOR_TOKEN is required", error.message
  end

  test "keeps the GitHub execution mode as a compatibility fallback" do
    adapter = RunDiff::Executor::Resolver.from_env(
      root: Rails.root,
      env: { "RUNDIFF_GITHUB_EXECUTION_MODE" => "local" },
      rails_env: ActiveSupport::EnvironmentInquirer.new("test")
    )

    assert_instance_of RunDiff::Executor::LocalAdapter, adapter
  end

  test "fails closed when execution is disabled" do
    error = assert_raises(RunDiff::Executor::Resolver::Error) do
      RunDiff::Executor::Resolver.from_env(
        root: Rails.root,
        env: { "RUNDIFF_EXECUTOR" => "disabled" },
        rails_env: ActiveSupport::EnvironmentInquirer.new("test")
      )
    end

    assert_equal "RunDiff executor is disabled", error.message
  end
end
