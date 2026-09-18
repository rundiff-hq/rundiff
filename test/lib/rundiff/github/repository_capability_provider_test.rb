require "test_helper"

class RunDiffGithubRepositoryCapabilityProviderTest < ActiveSupport::TestCase
  Execution = Data.define(
    :context,
    :status,
    :scenario_id,
    :baseline_sha,
    :candidate_sha,
    :attempt_count,
    :lease_expired
  ) do
    def lease_expired?
      lease_expired
    end
  end

  class ExecutionModel
    def initialize(execution)
      @execution = execution
    end

    def find_by(execution_id:)
      @execution if execution_id == "github-123"
    end
  end

  class Authentication
    attr_reader :calls

    def initialize
      @calls = []
    end

    def installation_token(**attributes)
      @calls << attributes
      RunDiff::Github::AppAuthentication::Token.new(
        value: "scoped-clone-token",
        expires_at: Time.utc(2026, 9, 5, 0, 0, 0)
      )
    end
  end

  test "mints a repository-scoped contents-read token for the exact live attempt" do
    authentication = Authentication.new
    provider = provider_for(execution: running_execution, authentication:)

    capability = provider.call(request: executor_request)

    assert_equal "scoped-clone-token", capability.token
    assert_equal(
      {
        installation_id: 159_078_958,
        repositories: [ "rundiff" ],
        permissions: { contents: "read" }
      },
      authentication.calls.fetch(0)
    )
  end

  test "does not mint a capability without durable GitHub installation context" do
    authentication = Authentication.new
    provider = provider_for(execution: nil, authentication:)

    assert_nil provider.call(request: executor_request)
    assert_empty authentication.calls
  end

  test "rejects a capability request that does not match the durable attempt" do
    authentication = Authentication.new
    provider = provider_for(execution: running_execution, authentication:)
    mismatched = RunDiff::Executor::Request.new(
      schema_version: executor_request.schema_version,
      execution_id: executor_request.execution_id,
      scenario_id: executor_request.scenario_id,
      baseline_sha: executor_request.baseline_sha,
      candidate_sha: "different-head",
      attempt_number: executor_request.attempt_number,
      context: executor_request.context
    )

    error = assert_raises(RunDiff::Github::RepositoryCapabilityProvider::Error) do
      provider.call(request: mismatched)
    end

    assert_equal "Repository capability request does not match the durable execution attempt", error.message
    assert_empty authentication.calls
  end

  test "rejects capability minting after the execution is no longer live" do
    authentication = Authentication.new
    provider = provider_for(
      execution: running_execution(status: "completed"),
      authentication:
    )

    error = assert_raises(RunDiff::Github::RepositoryCapabilityProvider::Error) do
      provider.call(request: executor_request)
    end

    assert_equal "Repository capability can only be minted for a live running execution", error.message
    assert_empty authentication.calls
  end

  private

  def provider_for(execution:, authentication:)
    RunDiff::Github::RepositoryCapabilityProvider.new(
      execution_model: ExecutionModel.new(execution),
      authentication:
    )
  end

  def running_execution(status: "running")
    Execution.new(
      context: {
        "installation_id" => 159_078_958,
        "repository" => "rundiff/rundiff",
        "candidate_repository" => "rundiff/rundiff",
        "pull_request_number" => 40
      },
      status:,
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
      attempt_count: 1,
      lease_expired: false
    )
  end

  def executor_request
    RunDiff::Executor::Request.new(
      schema_version: "1",
      execution_id: "github-123",
      scenario_id: "scenario",
      baseline_sha: "base",
      candidate_sha: "head",
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
end
