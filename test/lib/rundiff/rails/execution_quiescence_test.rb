require "test_helper"

class RunDiffRailsExecutionQuiescenceTest < ActiveSupport::TestCase
  setup do
    Current.reset
    RunDiffExecutionWorkItem.delete_all
  end

  teardown do
    Current.reset
    RunDiffExecutionWorkItem.delete_all
  end

  test "returns a terminal snapshot once execution is quiescent" do
    create_work_item(execution_id: "quiet-execution", status: "completed")

    snapshot = RunDiff::Rails::ExecutionQuiescence.wait(
      execution_id: "quiet-execution",
      timeout_seconds: 0.1,
      poll_interval_seconds: 0.001,
      quiet_period_seconds: 0
    )

    assert snapshot.fetch("quiescent")
    assert_equal 0, snapshot.fetch("pending_count")
    assert_equal [ "completed" ], snapshot.fetch("work_items").map { |item| item.fetch("status") }
    assert_operator snapshot.fetch("waited_ms"), :>=, 0
  end

  test "times out with the pending work snapshot" do
    create_work_item(execution_id: "stuck-execution", status: "enqueued", name: "StuckJob")

    error = assert_raises(RunDiff::Rails::ExecutionQuiescence::TimeoutError) do
      RunDiff::Rails::ExecutionQuiescence.wait(
        execution_id: "stuck-execution",
        timeout_seconds: 0.01,
        poll_interval_seconds: 0.001,
        quiet_period_seconds: 0
      )
    end

    assert_equal 1, error.snapshot.fetch("pending_count")
    assert_equal "enqueued", error.snapshot.fetch("work_items").first.fetch("status")
    assert_includes error.message, "StuckJob:work-1"
  end

  test "does not count quiescence bookkeeping as product SQL" do
    measurements = RunDiff::Rails::EvidenceCollector.capture(execution_id: "observed-execution") do
      Current.set(rundiff_execution_id: "observed-execution") do
        RunDiff::Rails::ExecutionQuiescence.snapshot(execution_id: "observed-execution")
      end
    end

    assert_equal 0, measurements.fetch("sql_queries")
  end

  private

  def create_work_item(execution_id:, status:, name: "ProbeJob")
    now = Time.current
    RunDiffExecutionWorkItem.create!(
      execution_id:,
      kind: "active_job",
      work_id: "work-1",
      name:,
      queue_name: "default",
      status:,
      enqueued_at: now,
      started_at: status == "enqueued" ? nil : now,
      finished_at: status.in?(RunDiffExecutionWorkItem::TERMINAL_STATUSES) ? now : nil
    )
  end
end
