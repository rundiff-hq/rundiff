require "test_helper"

class RunDiffExecutorServiceResolverTest < ActiveSupport::TestCase
  test "resolves the local worker adapter by default" do
    adapter = RunDiff::Executor::ServiceResolver.from_env(root: Rails.root, env: {})

    assert_instance_of RunDiff::Executor::LocalAdapter, adapter
  end

  test "resolves the repository clone worker adapter explicitly" do
    adapter = RunDiff::Executor::ServiceResolver.from_env(
      root: Rails.root,
      env: { "RUNDIFF_EXECUTOR_SERVICE_ADAPTER" => "git_clone" }
    )

    assert_instance_of RunDiff::Executor::GitCloneAdapter, adapter
  end

  test "fails closed for an unsupported service adapter" do
    error = assert_raises(RunDiff::Executor::ServiceResolver::Error) do
      RunDiff::Executor::ServiceResolver.from_env(
        root: Rails.root,
        env: { "RUNDIFF_EXECUTOR_SERVICE_ADAPTER" => "remote" }
      )
    end

    assert_equal 'Unsupported RUNDIFF_EXECUTOR_SERVICE_ADAPTER="remote"', error.message
  end

  test "can disable the executor service adapter explicitly" do
    error = assert_raises(RunDiff::Executor::ServiceResolver::Error) do
      RunDiff::Executor::ServiceResolver.from_env(
        root: Rails.root,
        env: { "RUNDIFF_EXECUTOR_SERVICE_ADAPTER" => "disabled" }
      )
    end

    assert_equal "RunDiff executor service adapter is disabled", error.message
  end
end
