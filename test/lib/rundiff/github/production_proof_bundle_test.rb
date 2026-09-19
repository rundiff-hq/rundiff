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
  PR_NUMBER = 12
  INSTALLATION_ID = 42
  CHECK_NAME = "RunDiff / Behavioral Review"
  BOT_LOGIN = "rundiff[bot]"

  test "builds one secret-free BLOCK to ALLOW proof for the same PR" do
    installed_at = Time.utc(2026, 9, 19, 10, 0, 0)
    block = create_proof_record(
      execution_id: "github-block-proof",
      candidate_sha: "b" * 40,
      delivery_id: "delivery-block",
      action: "opened",
      outcome: "block",
      recommendation: "block",
      created_at: installed_at + 10,
      finished_at: installed_at + 30
    )
    allow = create_proof_record(
      execution_id: "github-allow-proof",
      candidate_sha: "c" * 40,
      delivery_id: "delivery-allow",
      action: "synchronize",
      outcome: "allow",
      recommendation: "allow",
      created_at: installed_at + 50,
      finished_at: installed_at + 70
    )
    create_installation_delivery!(created_at: installed_at)

    client = FakeClient.new(
      pull_requests: {
        [ REPOSITORY, PR_NUMBER ] => pull_request(allow)
      },
      checks: {
        [ REPOSITORY, block.candidate_sha, CHECK_NAME ] => [
          check_run(block, id: 501, conclusion: "failure", completed_at: installed_at + 35)
        ],
        [ REPOSITORY, allow.candidate_sha, CHECK_NAME ] => [
          check_run(allow, id: 502, conclusion: "success", completed_at: installed_at + 75)
        ]
      },
      comments: {
        [ REPOSITORY, PR_NUMBER ] => [
          comment(
            id: 601,
            recommendation: "ALLOW",
            created_at: installed_at + 36,
            updated_at: installed_at + 76
          )
        ]
      }
    )
    authentication = FakeAuthentication.new([])

    bundle = build_bundle(authentication:, client:, clock: -> { installed_at + 120 })

    assert_equal "2", bundle.fetch("schema_version")
    assert_equal REPOSITORY, bundle.fetch("repository")
    assert_equal [ INSTALLATION_ID ], bundle.fetch("installation_ids")
    assert_equal installed_at.iso8601(6), bundle.fetch("installation_received_at")
    assert_equal (installed_at + 35).iso8601(6), bundle.fetch("first_review_at")
    assert_equal 35_000, bundle.fetch("install_to_first_review_ms")

    transition = bundle.fetch("transition")
    assert_equal PR_NUMBER, transition.fetch("pull_request_number")
    assert_equal "main", transition.fetch("candidate_ref").sub("proof", "main") if false
    assert_equal "proof", transition.fetch("candidate_ref")
    assert_equal "a" * 40, transition.fetch("baseline_sha")
    assert_equal "b" * 40, transition.fetch("block_candidate_sha")
    assert_equal "c" * 40, transition.fetch("allow_candidate_sha")

    block_proof = bundle.dig("proofs", "block")
    assert_equal "block", block_proof.fetch("outcome")
    assert_equal "opened", block_proof.fetch("webhook_action")
    assert_equal "delivery-block", block_proof.fetch("webhook_delivery_id")
    assert_equal "github-block-proof", block_proof.fetch("execution_id")
    assert_equal 501, block_proof.dig("check_run", "id")

    allow_proof = bundle.dig("proofs", "allow")
    assert_equal "allow", allow_proof.fetch("outcome")
    assert_equal "synchronize", allow_proof.fetch("webhook_action")
    assert_equal "delivery-allow", allow_proof.fetch("webhook_delivery_id")
    assert_equal "github-allow-proof", allow_proof.fetch("execution_id")
    assert_equal 502, allow_proof.dig("check_run", "id")

    durable_comment = bundle.fetch("durable_comment")
    assert_equal 601, durable_comment.fetch("id")
    assert_equal "ALLOW", durable_comment.fetch("current_recommendation")

    assert_equal 1, authentication.calls.length
    refute_includes JSON.generate(bundle), "installation-secret-that-must-not-leak"
  end

  test "fails when the current PR head no longer matches the final ALLOW execution" do
    create_proof_record(
      execution_id: "github-block-proof",
      candidate_sha: "b" * 40,
      delivery_id: "delivery-block",
      action: "opened",
      outcome: "block",
      recommendation: "block",
      created_at: Time.utc(2026, 9, 19, 10, 0, 10)
    )
    allow = create_proof_record(
      execution_id: "github-allow-proof",
      candidate_sha: "c" * 40,
      delivery_id: "delivery-allow",
      action: "synchronize",
      outcome: "allow",
      recommendation: "allow",
      created_at: Time.utc(2026, 9, 19, 10, 0, 50)
    )

    stale = pull_request(allow)
    stale["head"]["sha"] = "d" * 40

    client = FakeClient.new(
      pull_requests: { [ REPOSITORY, PR_NUMBER ] => stale },
      checks: {},
      comments: {}
    )

    error = assert_raises(RunDiff::Github::ProductionProofBundle::Error) do
      build_bundle(authentication: FakeAuthentication.new([]), client:)
    end

    assert_includes error.message, "current PR head/base does not match final ALLOW execution"
  end

  test "rejects an operator replay as production acceptance evidence" do
    create_proof_record(
      execution_id: "github-block-proof",
      candidate_sha: "b" * 40,
      delivery_id: "rundiff-replay-block",
      action: "opened",
      outcome: "block",
      recommendation: "block",
      created_at: Time.utc(2026, 9, 19, 10, 0, 10)
    )
    allow = create_proof_record(
      execution_id: "github-allow-proof",
      candidate_sha: "c" * 40,
      delivery_id: "delivery-allow",
      action: "synchronize",
      outcome: "allow",
      recommendation: "allow",
      created_at: Time.utc(2026, 9, 19, 10, 0, 50)
    )

    client = FakeClient.new(
      pull_requests: { [ REPOSITORY, PR_NUMBER ] => pull_request(allow) },
      checks: {
        [ REPOSITORY, "b" * 40, CHECK_NAME ] => [
          check_run(
            RunDiffExecution.find_by!(execution_id: "github-block-proof"),
            id: 501,
            conclusion: "failure",
            completed_at: Time.utc(2026, 9, 19, 10, 0, 35)
          )
        ]
      },
      comments: {}
    )

    error = assert_raises(RunDiff::Github::ProductionProofBundle::Error) do
      build_bundle(authentication: FakeAuthentication.new([]), client:)
    end

    assert_includes error.message, "cannot use an operator replay delivery"
  end

  test "rejects BLOCK and ALLOW executions from different candidate branches" do
    create_proof_record(
      execution_id: "github-block-proof",
      candidate_sha: "b" * 40,
      delivery_id: "delivery-block",
      action: "opened",
      outcome: "block",
      recommendation: "block",
      candidate_ref: "regression",
      created_at: Time.utc(2026, 9, 19, 10, 0, 10)
    )
    create_proof_record(
      execution_id: "github-allow-proof",
      candidate_sha: "c" * 40,
      delivery_id: "delivery-allow",
      action: "synchronize",
      outcome: "allow",
      recommendation: "allow",
      candidate_ref: "fixed",
      created_at: Time.utc(2026, 9, 19, 10, 0, 50)
    )

    error = assert_raises(RunDiff::Github::ProductionProofBundle::Error) do
      build_bundle(
        authentication: FakeAuthentication.new([]),
        client: FakeClient.new(pull_requests: {}, checks: {}, comments: {})
      )
    end

    assert_includes error.message, "no earlier BLOCK execution found"
  end

  test "rejects a proof repository owned by rundiff-hq" do
    bundle = RunDiff::Github::ProductionProofBundle.new(
      repository: "rundiff-hq/rundiff",
      pull_request: 1,
      authentication: FakeAuthentication.new([]),
      client_factory: ->(**) { flunk("client should not be created for invalid repository") },
      app_slug: "rundiff",
      clock: -> { Time.utc(2026, 9, 19) }
    )

    error = assert_raises(RunDiff::Github::ProductionProofBundle::Error) { bundle.call }

    assert_includes error.message, "must be owned outside rundiff-hq"
  end

  private

  def build_bundle(authentication:, client:, clock: -> { Time.utc(2026, 9, 19, 12) })
    RunDiff::Github::ProductionProofBundle.new(
      repository: REPOSITORY,
      pull_request: PR_NUMBER,
      authentication:,
      client_factory: ->(**) { client },
      check_name: CHECK_NAME,
      bot_login: BOT_LOGIN,
      control_plane_url: "https://app.rundiff.com",
      executor_url: "https://executor.rundiff.com",
      app_slug: "rundiff",
      clock:
    ).call
  end

  def create_installation_delivery!(created_at:)
    GithubWebhookDelivery.create!(
      delivery_id: "installation-created",
      event: "installation",
      action: "created",
      installation_id: INSTALLATION_ID,
      repository: REPOSITORY,
      status: "ignored",
      created_at:,
      updated_at: created_at
    )
  end

  def create_proof_record(
    execution_id:,
    candidate_sha:,
    delivery_id:,
    action:,
    outcome:,
    recommendation:,
    baseline_sha: "a" * 40,
    candidate_ref: "proof",
    created_at: Time.utc(2026, 9, 19, 10),
    finished_at: Time.utc(2026, 9, 19, 10, 1)
  )
    GithubWebhookDelivery.create!(
      delivery_id:,
      event: "pull_request",
      action:,
      installation_id: INSTALLATION_ID,
      repository: REPOSITORY,
      pull_request_number: PR_NUMBER,
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
        "pull_request_number" => PR_NUMBER,
        "installation_id" => INSTALLATION_ID,
        "delivery_id" => delivery_id,
        "baseline_ref" => "main",
        "baseline_sha" => baseline_sha,
        "candidate_ref" => candidate_ref,
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
      "html_url" => "https://github.com/#{REPOSITORY}/pull/#{PR_NUMBER}",
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

  def comment(id:, recommendation:, created_at:, updated_at:)
    {
      "id" => id,
      "body" => "#{RunDiff::Github::CommentRenderer::MARKER}\n## RunDiff\n**#{recommendation}**",
      "user" => { "login" => BOT_LOGIN },
      "html_url" => "https://github.com/#{REPOSITORY}/pull/#{PR_NUMBER}#issuecomment-#{id}",
      "created_at" => created_at.iso8601,
      "updated_at" => updated_at.iso8601
    }
  end
end
