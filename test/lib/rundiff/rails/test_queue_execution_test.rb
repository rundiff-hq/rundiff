require "test_helper"

class RunDiffRealQueueProbeJob < ApplicationJob
  CONTEXT_EVENT = "rundiff.real_queue_probe"

  def perform
    ActiveSupport::Notifications.instrument(
      CONTEXT_EVENT,
      execution_id: Current.rundiff_execution_id,
      run_id: Current.rundiff_run_id,
      subject: Current.rundiff_subject
    )
    ApplicationRecord.connection.select_value("SELECT 1")
  end
end

class RunDiffQueueFanoutChildJob < ApplicationJob
  def perform
  end
end

class RunDiffQueueFanoutParentJob < ApplicationJob
  def perform
    RunDiffQueueFanoutChildJob.perform_later
  end
end

class RunDiffRailsTestQueueExecutionTest < ActiveSupport::TestCase
  setup do
    Current.reset
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
    RunDiffEvidenceEvent.delete_all
    RunDiffExecutionWorkItem.delete_all
  end

  teardown do
    Current.reset
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
    RunDiffEvidenceEvent.delete_all
    RunDiffExecutionWorkItem.delete_all
  end

  test "executes the actual queued payload and closes its durable work lifecycle" do
    execution_id = "real-queue-execution-123"
    observed_context = nil
    subscriber = ActiveSupport::Notifications.subscribe(RunDiffRealQueueProbeJob::CONTEXT_EVENT) do |event|
      observed_context = event.payload
    end

    Current.set(
      rundiff_execution_id: execution_id,
      rundiff_run_id: "real-queue-run-456",
      rundiff_subject: "candidate"
    ) do
      RunDiffRealQueueProbeJob.perform_later
    end

    queued = ActiveJob::Base.queue_adapter.enqueued_jobs.first
    serialized_context = queued.fetch(RunDiff::Rails::ActiveJobExecutionContext::CONTEXT_KEY)
    queued_job_id = queued.fetch("job_id")
    work_item = RunDiffExecutionWorkItem.find_by!(execution_id:, work_id: queued_job_id)

    assert_equal "enqueued", work_item.status
    assert_equal "active_job", work_item.kind
    assert_equal "RunDiffRealQueueProbeJob", work_item.name
    assert_equal "default", work_item.queue_name
    assert_equal "real-queue-run-456", work_item.run_id
    assert_equal "candidate", work_item.subject
    assert_not_nil work_item.enqueued_at
    assert_nil work_item.started_at
    assert_nil work_item.finished_at
    assert_not RunDiff::Rails::ExecutionWorkLifecycle.quiescent?(execution_id:)
    assert_equal 1, RunDiff::Rails::ExecutionWorkLifecycle.pending_count(execution_id:)

    Current.reset
    assert_nil Current.rundiff_execution_id

    executions = RunDiff::Rails::TestQueueExecution.drain(execution_id:)
    quiescence = RunDiff::Rails::ExecutionQuiescence.wait(execution_id:, quiet_period_seconds: 0)

    assert_equal 1, executions.size
    assert_equal "RunDiffRealQueueProbeJob", executions.first.fetch("job_class")
    assert_equal queued_job_id, executions.first.fetch("job_id")
    assert_equal "application_enqueue", executions.first.fetch("source")
    assert_equal execution_id, serialized_context.fetch("rundiff_execution_id")
    assert_equal execution_id, observed_context.fetch(:execution_id)
    assert_equal "real-queue-run-456", observed_context.fetch(:run_id)
    assert_equal "candidate", observed_context.fetch(:subject)
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs

    work_item.reload
    assert_equal "completed", work_item.status
    assert_not_nil work_item.started_at
    assert_not_nil work_item.finished_at
    assert_nil work_item.error_class
    assert work_item.terminal?
    assert quiescence.fetch("quiescent")
    assert_equal 0, quiescence.fetch("pending_count")

    record = RunDiffEvidenceEvent.find_by!(execution_id:, signal: "sql_queries")
    assert_equal "RunDiffRealQueueProbeJob", record.producer_name
    assert_equal queued_job_id, record.producer_id
    assert_equal "test/lib/rundiff/rails/test_queue_execution_test.rb", record.path
    assert_nil Current.rundiff_execution_id
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "drives correlated child jobs until the durable execution becomes quiescent" do
    execution_id = "fanout-execution"

    Current.set(
      rundiff_execution_id: execution_id,
      rundiff_run_id: "fanout-run",
      rundiff_subject: "candidate"
    ) do
      RunDiffQueueFanoutParentJob.perform_later
    end

    executions = RunDiff::Rails::TestQueueExecution.drain(execution_id:)
    quiescence = RunDiff::Rails::ExecutionQuiescence.wait(execution_id:, quiet_period_seconds: 0)
    work_items = RunDiffExecutionWorkItem.where(execution_id:).order(:id).to_a

    assert_equal %w[RunDiffQueueFanoutParentJob RunDiffQueueFanoutChildJob], executions.map { |item| item.fetch("job_class") }
    assert_equal 2, work_items.size
    assert work_items.all?(&:terminal?)
    assert_equal %w[completed completed], work_items.map(&:status)
    assert quiescence.fetch("quiescent")
    assert_equal 0, quiescence.fetch("pending_count")
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
  end

  test "leaves jobs and lifecycle state from other executions pending" do
    Current.set(rundiff_execution_id: "execution-a") { DemoNotificationJob.perform_later }
    Current.set(rundiff_execution_id: "execution-b") { DemoNotificationJob.perform_later }

    assert_equal 1, RunDiff::Rails::ExecutionWorkLifecycle.pending_count(execution_id: "execution-a")
    assert_equal 1, RunDiff::Rails::ExecutionWorkLifecycle.pending_count(execution_id: "execution-b")

    executions = RunDiff::Rails::TestQueueExecution.drain(execution_id: "execution-a")
    quiescence = RunDiff::Rails::ExecutionQuiescence.wait(execution_id: "execution-a", quiet_period_seconds: 0)

    assert_equal 1, executions.size
    assert_equal "execution-a", executions.first.fetch("execution_id")
    assert quiescence.fetch("quiescent")
    assert_not RunDiff::Rails::ExecutionWorkLifecycle.quiescent?(execution_id: "execution-b")
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
    remaining_context = ActiveJob::Base.queue_adapter.enqueued_jobs.first.fetch(
      RunDiff::Rails::ActiveJobExecutionContext::CONTEXT_KEY
    )
    assert_equal "execution-b", remaining_context.fetch("rundiff_execution_id")
  end
end
