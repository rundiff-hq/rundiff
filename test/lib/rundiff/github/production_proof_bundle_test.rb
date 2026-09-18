require "test_helper"

class RunDiffGithubProductionProofBundleTest < ActiveSupport::TestCase
  FakeToken = Data.define(:value)
  FakeAuthentication = Struct.new(:calls) do
    def installation_token(installation_id:, repositories:)
      calls << { installation_id:, repositories: }
      FakeToken.new("installation-secret-that-must-not-leak")
    end
  end

  class FakeClient
    attr_reader :pull_requests, :checks, :comments_by_pr

    def initialize(pull_requests:, checks:, comments:)
      @pull_requests = pull_requests
      @checks = checks
      @comments_by_pr = comments
    end

    def pull_request(repository:, number:)
      pull_requests.fetch([ repository, number ])
    end

    def check_runs(repository:, head_sha:, name:)
      checks.fetch([ repository, head_sha, name ])
    end

    def comments(repository:, number:)
      comments_by_pr.fetch([ repository, number ])
    end
  end

  REPOSITORY = "external-owner/proof-repo"
  INSTALLATION_ID = 42
  CHECK_NAME = "RunDiff / Behavioral Diff"
  BOT_LOGIN = "rundiff[bot]"

  test "builds one secret-free bundle for BLOCK and ALLOW proof PRs" do
    installed_at = Time.utc(2026, 9, 18, 10, 0, 0)
    regression = create_proof_records(
      pr_number: 12,
      execution_id: "github-regression-proof",
      baseline_sha: "a" * 40,
      candidate_sha: "b" * 40,
      delivery_id: "delivery-regression",
      outcome: "block",
      recommendation: "block",
      created_at: installed_at + 10,
      finished_at: installed_at + 30
    )
    neutral = create_proof_records(
      pr_number: 13,
      execution_id: "github-neutral-proof",
      baseline_sha: "c" * 40,
      candidate_sha: "d" * 40,
      delivery_id: "delivery-neutral",
      outcome: "allow",
      recommendation: "allow",
      created_at: installed_at + 40,
      finished_at: installed_at + 60
    )
    GithubWebhookDelivery.create!(
      delivery_id: "installation-created",
      event: "installation",
      action: "created",
      installation_id: INSTALLATION_ID,
      repository: REPOSITORY,
      status: "ignored",
      created_at: installed_at,
      updated_at: installed_at
    )

    client = FakeClient.new(
      pull_requests: {
        [ REPOSITORY, 12 ] => pull_request(regression),
        [ REPOSITORY, 13 ] => pull_request(neutral)
      },
      checks: {
        [ REPOSITORY, regression.candidate_sha, CHECK_NAME ] => [
          check_run(regression, id: 501, conclusion: "failure", completed_at: installed_at + 35)
        ],
        [ REPOSITORY, neutral.candidate_sha, CHECK_NAME ] => [
          check_run(neutral, id: 502, conclusion: "success", completed_at: installed_at + 65)
        ]
      },
      comments: {
        [ REPOSITORY, 12 ] => [
          comment(id: 601, recommendation: "BLOCK", created_at: installed_at + 36)
        ],
        [ REPOSITORY, 13 ] => [
          comment(id: 602, recommendation: "ALLOW", created_at: installed_at + 66)
        ]
      }
    )
    authentication = FakeAuthentication.new([])

    bundle = build_bundle(authentication:, client:, clock: -> { installed_at + 120 })

    assert_equal "1", bundle.fetch("schema_version")
    assert_equal REPOSITORY, bundle.fetch("repository")
    assert_equal [ INSTALLATION_ID ], bundle.fetch("installation_ids")
    assert_equal installed_at.iso8601(6), bundle.fetch("installation_received_at")
    assert_equal (installed_at + 35).iso8601(6), bundle.fetch("first_review_at")
    assert_equal 35_000, bundle.fetch("install_to_first_review_ms")

    regression_proof = bundle.dig("proofs", "regression")
    assert_equal "block", regression_proof.fetch("outcome")
    assert_equal "delivery-regression", regression_proof.fetch("webhook_delivery_id")
    assert_equal "github-regression-proof", regression_proof.fetch("execution_id")
    assert_equal 501, regression_proof.dig("check_run", "id")
    assert_equal 601, regression_proof.dig("comment", "id")

    neutral_proof = bundle.dig("proofs", "neutral")
    assert_equal "allow", neutral_proof.fetch("outcome")
    assert_equal 502, neutral_proof.dig("check_run", "id")
    assert_equal 602, neutral_proof.dig("comment", "id")

    assert_equal 2, authentication.calls.length
    refute_includes JSON.generate(bundle), "installation-secret-that-must-not-leak"
  end

  test "fails when the current PR head no longer matches the durable execution" do
    execution = create_proof_records(
      pr_number: 12,
      execution_id: "github-stale-proof",
      baseline_sha: "a" * 40,
      candidate_sha: "b" * 40,
      delivery_id: "delivery-stale",
      outcome: "block",
      recommendation: "block"
    )
    create_proof_records(
      pr_number: 13,
      execution_id: "github-neutral-proof",
      baseline_sha: "c" * 40,
      candidate_sha: "d" * 40,
      delivery_id: "delivery-neutral",
      outcome: "allow",
      recommendation: "allow"
    )

    client = FakeClient.new(
      pull_requests: {
        [ REPOSITORY, 12 ] => pull_request(execution).tap { |payload| payload["head"]["sha"] = "e" * 40 },
        [ REPOSITORY, 13 ] => {
          "html_url" => "https://github.com/#{REPOSITORY}/pull/13",
          "base" => { "sha" => "c" * 40 },
          "head" => { "sha" => "d" * 40 }
        }
      },
      checks: {},
      comments: {}
    )

    error = assert_raises(RunDiff::Github::ProductionProofBundle::Error) do
      build_bundle(authentication: FakeAuthentication.new([]), client:)
    end

    assert_includes error.message, "PR head/base is stale"
  end

  test "rejects a proof repository owned by rundiff-hq" do
    bundle = RunDiff::Github::ProductionProofBundle.new(
      repository: "rundiff-hq/rundiff",
      regression_pr: 1,
      neutral_pr: 2,
      authentication: FakeAuthentication.new([]),
      client_factory: ->(token:) { flunk("client should not be created for invalid repository") },
      app_slug: "rundiff",
      clock: -> { Time.utc(2026, 9, 18) }
    )

    error = assert_raises(RunDiff::Github::ProductionProofBundle::Error) { bundle.call }

    assert_includes error.message, "must be owned outside rundiff-hq"
  end

  private

  def build_bundle(authentication:, client:, clock: -> { Time.utc(2026, 9, 18, 12) })
    RunDiff::Github::ProductionProofBundle.new(
      repository: REPOSITORY,
      regression_pr: 12,
      neutral_pr: 13,
      authentication:,
      client_factory: ->(token:) { client },
      check_name: CHECK_NAME,
      bot_login: BOT_LOGIN,
      control_plane_url: "https://app.rundiff.com",
      executor_url: "https://executor.rundiff.com",
      app_slug: "rundiff",
      clock:
    ).call
  end

  def create_proof_records(
    pr_number:,
    execution_id:,
    baseline_sha:,
    candidate_sha:,
    delivery_id:,
    outcome:,
    recommendation:,
    created_at: Time.utc(2026, 9, 18, 10),
    finished_at: Time.utc(2026, 9, 18, 10, 1)
  )
    GithubWebhookDelivery.create!(
      delivery_id:,
      event: "pull_request",
      action: "synchronize",
      installation_id: INSTALLATION_ID,
      repository: REPOSITORY,
      pull_request_number: pr_number,
      base_sha: baseline_sha,
      head_sha: candidate_sha,
      status: "completed"
    )

    RunDiffExecution.create!(
      execution_id:,
      source: "github_pull_request",
      scenario_id: "production-proof",
      baseline_sha:,
      candidate_sha:,
      status: "completed",
      outcome:,
      decision: recommendation == "block" ? "regression" : "no_regression",
      result: {
        "result" => {
          "merge_recommendation" => recommendation
        }
      },
      context: {
        "repository" => REPOSITORY,
        "pull_request_number" => pr_number,
        "installation_id" => INSTALLATION_ID,
        "delivery_id" => delivery_id,
        "baseline_ref" => "main",
        "baseline_sha" => baseline_sha,
        "candidate_ref" => "proof-#{pr_number}",
        "candidate_sha" => candidate_sha,
        "candidate_repository" => REPOSITORY
      },
      created_at:,
      updated_at: finished_at,
      finished_at:
    )
  end

  def pull_request(execution)
    {
      "html_url" => "https://github.com/#{REPOSITORY}/pull/#{execution.context.fetch("pull_request_number")}",
      "base" => { "sha" => execution.baseline_sha },
      "head" => { "sha" => execution.candidate_sha }
    }
  end

  def check_run(execution, id:, conclusion:, completed_at:)
    {
      "id" => id,
      "name" => CHECK_NAME,
      "external_id" => execution.execution_id,
      "status" => "completed",
      "conclusion" => conclusion,
      "html_url" => "https://github.com/#{REPOSITORY}/runs/#{id}",
      "completed_at" => completed_at.iso8601
    }
  end

  def comment(id:, recommendation:, created_at:)
    {
      "id" => id,
      "body" => "#{RunDiff::Github::CommentRenderer::MARKER}\n## RunDiff\n**#{recommendation}**",
      "user" => { "login" => BOT_LOGIN },
      "html_url" => "https://github.com/#{REPOSITORY}/pull/1#issuecomment-#{id}",
      "created_at" => created_at.iso8601,
      "updated_at" => created_at.iso8601
    }
  end
end
