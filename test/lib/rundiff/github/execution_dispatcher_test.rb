require "test_helper"

class RunDiffGithubExecutionDispatcherTest < ActiveSupport::TestCase
  test "reuses one durable execution and safely re-enqueues while it is queued" do
    delivery = create_delivery
    pull_request = pull_request_payload
    dispatcher = RunDiff::Github::ExecutionDispatcher.new(scenario_id: "scenario")

    first, first_enqueue = dispatcher.call(delivery:, pull_request:)
    second, second_enqueue = dispatcher.call(delivery:, pull_request:)

    assert first_enqueue
    assert second_enqueue
    assert_equal first.id, second.id
    assert_equal "queued", first.status
    assert_match(/\Agithub-[0-9a-f]{64}\z/, first.execution_id)
  end

  test "records execution orchestrator provenance outside the portable request" do
    previous = ENV["RUNDIFF_EXECUTION_ORCHESTRATOR"]
    ENV["RUNDIFF_EXECUTION_ORCHESTRATOR"] = "github_actions"

    delivery = create_delivery
    execution, = RunDiff::Github::ExecutionDispatcher.new(scenario_id: "scenario").call(
      delivery:,
      pull_request: pull_request_payload
    )

    assert_equal "github_actions", execution.context.fetch("execution_orchestrator")
    request = RunDiff::Executor::Request.from_execution(execution)
    refute_includes request.context, "execution_orchestrator"
  ensure
    ENV["RUNDIFF_EXECUTION_ORCHESTRATOR"] = previous
  end

  test "cancels an older active revision of the same pull request" do
    notification_job = recording_notification_job
    cancellation = RunDiff::Executor::Cancellation.new(notification_job:)
    dispatcher = RunDiff::Github::ExecutionDispatcher.new(
      scenario_id: "scenario",
      cancellation:
    )
    delivery = create_delivery
    first, = dispatcher.call(delivery:, pull_request: pull_request_payload)
    first.claim!

    newer_pull_request = pull_request_payload.deep_dup
    newer_pull_request["head"]["sha"] = "new-head-sha"
    newer, enqueue = dispatcher.call(delivery:, pull_request: newer_pull_request)

    assert enqueue
    refute_equal first.id, newer.id
    first.reload
    assert_equal "cancelled", first.status
    assert_equal "cancelled", first.outcome
    assert_equal "superseded_by_new_pull_request_revision", first.cancellation_reason
    assert_equal [ [ first.execution_id, 1, "superseded_by_new_pull_request_revision" ] ], notification_job.calls
    assert_equal "queued", newer.status
  end

  test "does not cancel an active execution from another pull request" do
    dispatcher = RunDiff::Github::ExecutionDispatcher.new(scenario_id: "scenario")
    other_delivery = create_delivery(pull_request_number: 99)
    other, = dispatcher.call(delivery: other_delivery, pull_request: pull_request_payload)
    other.claim!

    dispatcher.call(delivery: create_delivery, pull_request: pull_request_payload.merge(
      "head" => pull_request_payload.fetch("head").merge("sha" => "new-head-sha")
    ))

    assert_equal "running", other.reload.status
  end

  test "does not re-enqueue a completed execution for the same identity" do
    delivery = create_delivery
    dispatcher = RunDiff::Github::ExecutionDispatcher.new(scenario_id: "scenario")
    execution, = dispatcher.call(delivery:, pull_request: pull_request_payload)
    execution.update!(status: "completed", decision: "allow", outcome: "allow", finished_at: Time.current)

    existing, enqueue = dispatcher.call(delivery:, pull_request: pull_request_payload)

    refute enqueue
    assert_equal execution.id, existing.id
    assert_equal "completed", existing.status
  end

  test "requeues an infra failure for the same identity" do
    delivery = create_delivery
    dispatcher = RunDiff::Github::ExecutionDispatcher.new(scenario_id: "scenario")
    execution, = dispatcher.call(delivery:, pull_request: pull_request_payload)
    execution.claim!
    execution.fail!(RuntimeError.new("boom"))

    retried, enqueue = dispatcher.call(delivery:, pull_request: pull_request_payload)

    assert enqueue
    assert_equal execution.id, retried.id
    assert_equal "queued", retried.status
    assert_nil retried.outcome
    assert_nil retried.failure
    assert_nil retried.finished_at
  end

  test "does not requeue a failed execution without an infra failure outcome" do
    delivery = create_delivery
    dispatcher = RunDiff::Github::ExecutionDispatcher.new(scenario_id: "scenario")
    execution, = dispatcher.call(delivery:, pull_request: pull_request_payload)
    execution.update!(status: "failed", failure: "manual stop", finished_at: Time.current)

    existing, enqueue = dispatcher.call(delivery:, pull_request: pull_request_payload)

    refute enqueue
    assert_equal execution.id, existing.id
    assert_equal "failed", existing.status
  end

  private

  def create_delivery(pull_request_number: 31)
    GithubWebhookDelivery.create!(
      delivery_id: "delivery-#{SecureRandom.hex(4)}",
      event: "pull_request",
      action: "synchronize",
      installation_id: 123,
      repository: "rundiff/rundiff",
      pull_request_number:,
      base_sha: "old-base",
      head_sha: "head-sha"
    )
  end

  def pull_request_payload
    {
      "base" => { "ref" => "main", "sha" => "base-sha" },
      "head" => {
        "ref" => "feature",
        "sha" => "head-sha",
        "repo" => { "full_name" => "rundiff/rundiff" }
      }
    }
  end

  def recording_notification_job
    Struct.new(:calls) do
      def perform_later(*arguments)
        calls << arguments
      end
    end.new([])
  end
end
