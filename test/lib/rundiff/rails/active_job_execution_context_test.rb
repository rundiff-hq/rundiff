require "test_helper"

class RunDiffContextProbeJob < ApplicationJob
  CONTEXT_EVENT = "context_probe.rundiff"

  def perform
    ActiveSupport::Notifications.instrument(
      CONTEXT_EVENT,
      execution_id: Current.rundiff_execution_id,
      run_id: Current.rundiff_run_id,
      subject: Current.rundiff_subject
    )

    ApplicationRecord.connection.select_value("SELECT 1")
    DemoMailer.notification(Current.rundiff_execution_id).deliver_now
    Net::HTTP.get(URI.parse(RunDiff::Demo::LoopbackHttpServer.url))
  end
end

class RunDiffRailsActiveJobExecutionContextTest < ActiveSupport::TestCase
  teardown do
    Current.reset
  end

  test "serializes RunDiff execution context without changing job arguments" do
    serialized = Current.set(
      rundiff_execution_id: "execution-123",
      rundiff_run_id: "run-456",
      rundiff_subject: "candidate"
    ) do
      RunDiffContextProbeJob.new.serialize
    end

    assert_equal [], serialized.fetch("arguments")
    assert_equal(
      {
        "rundiff_execution_id" => "execution-123",
        "rundiff_run_id" => "run-456",
        "rundiff_subject" => "candidate"
      },
      serialized.fetch(RunDiff::Rails::ActiveJobExecutionContext::CONTEXT_KEY)
    )
  end

  test "serializes trusted queue timing capability" do
    serialized = with_clock_domain("boot-a") do
      Current.set(
        rundiff_execution_id: "execution-queue-123",
        rundiff_run_id: "run-queue-456",
        rundiff_subject: "candidate"
      ) do
        RunDiffContextProbeJob.new.serialize
      end
    end

    timing = serialized.fetch(RunDiff::Rails::ActiveJobExecutionContext::QUEUE_TIMING_KEY)
    assert_equal 1, timing.fetch("version")
    assert_equal "boot-a", timing.fetch("clock_domain_id")
    assert_equal 0.0, timing.fetch("scheduled_delay_ms")
    assert_kind_of Float, timing.fetch("enqueued_monotonic_seconds")
  end

  test "restores context after a serialize deserialize boundary and attributes job evidence" do
    execution_id = "async-execution-123"
    serialized = Current.set(
      rundiff_execution_id: execution_id,
      rundiff_run_id: "async-run-456",
      rundiff_subject: "candidate"
    ) do
      RunDiffContextProbeJob.new.serialize
    end

    Current.reset
    assert_nil Current.rundiff_execution_id

    job = ActiveJob::Base.deserialize(serialized)
    observed_context = nil
    subscriber = ActiveSupport::Notifications.subscribe(RunDiffContextProbeJob::CONTEXT_EVENT) do |event|
      observed_context = event.payload
    end

    collector = RunDiff::Rails::EvidenceCollector.new(execution_id:)
    measurements = collector.capture { job.perform_now }

    assert_equal "async-execution-123", observed_context.fetch(:execution_id)
    assert_equal "async-run-456", observed_context.fetch(:run_id)
    assert_equal "candidate", observed_context.fetch(:subject)
    assert_equal 1, measurements.fetch("sql_queries")
    assert_equal 0, measurements.fetch("background_jobs")
    assert_equal 1, measurements.fetch("emails")
    assert_equal 1, measurements.fetch("http_requests")
    assert_equal 0, measurements.fetch("errors")
    assert_equal "test/lib/rundiff/rails/active_job_execution_context_test.rb", collector.attributions.fetch("sql_queries").first.fetch("path")
    assert_equal "test/lib/rundiff/rails/active_job_execution_context_test.rb", collector.attributions.fetch("emails").first.fetch("path")
    assert_equal "test/lib/rundiff/rails/active_job_execution_context_test.rb", collector.attributions.fetch("http_requests").first.fetch("path")
    assert_nil Current.rundiff_execution_id
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  private

  def with_clock_domain(value)
    key = RunDiff::Rails::HostClockDomain::EXPLICIT_DOMAIN_ENV
    previous = ENV[key]
    ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end
end
