require "test_helper"

class RunDiffQueueWaitProbeJob < ApplicationJob
  def perform
  end
end

class RunDiffQueueWaitSignalTest < ActiveSupport::TestCase
  teardown do
    Current.reset
  end

  test "captures enqueue-to-start delay as durable per-job evidence without using work-item wall clocks" do
    execution_id = "queue-wait-execution"
    job = RunDiffQueueWaitProbeJob.new

    with_clock_domain("queue-wait-domain") do
      serialized = Current.set(
        rundiff_execution_id: execution_id,
        rundiff_run_id: "queue-wait-run",
        rundiff_subject: "candidate"
      ) do
        job.serialize
      end
      serialized.fetch(RunDiff::Rails::ActiveJobExecutionContext::QUEUE_TIMING_KEY)["enqueued_monotonic_seconds"] -= 0.2

      RunDiffExecutionWorkItem.create!(
        execution_id:,
        kind: "active_job",
        work_id: job.job_id,
        status: "enqueued",
        enqueued_at: Time.current + 1.day
      )

      Current.reset
      ActiveJob::Base.deserialize(serialized).perform_now
    end

    event = RunDiffEvidenceEvent.find_by!(execution_id:, signal: "queue_wait_ms")
    assert_operator event.payload.fetch("value"), :>=, 150.0
    assert_equal "enqueue_to_start", event.payload.fetch("semantics")
    assert_equal "host_monotonic_same_boot", event.payload.fetch("timing_authority")
    assert_equal "queue-wait-domain", event.payload.fetch("clock_domain_id")
    assert_equal "RunDiffQueueWaitProbeJob", event.producer_name
  end

  test "reduces multiple queue waits to the worst observed job instead of summing them" do
    execution = {
      "measurements" => {},
      "durable_observations" => [
        runtime_observation("queue_wait_ms", 12.0, "job-1"),
        runtime_observation("queue_wait_ms", 85.0, "job-2"),
        runtime_observation("queue_wait_ms", 40.0, "job-3"),
        runtime_observation("worker_wall_ms", 20.0, "job-1"),
        runtime_observation("worker_thread_cpu_ms", 2.0, "job-1")
      ]
    }

    reduced = RunDiff::ExecutionReducer.call(execution:)

    assert_equal 85.0, reduced.dig("measurements", "queue_wait_ms")
    assert_equal "queue_bound", reduced.dig("runtime_profile", "async", "classification")
    assert_equal 81.0, reduced.dig("runtime_profile", "async", "queue_share_percent")
  end

  test "reports queue wait regression separately from worker runtime" do
    result = RunDiff::BehavioralDiff.call(
      baseline: {
        queue_wait_ms: 8,
        worker_wall_ms: 30,
        worker_thread_cpu_ms: 3,
        sql_queries: 1,
        background_jobs: 1,
        emails: 0,
        http_requests: 0,
        errors: 0
      },
      candidate: {
        queue_wait_ms: 110,
        worker_wall_ms: 32,
        worker_thread_cpu_ms: 3,
        sql_queries: 1,
        background_jobs: 1,
        emails: 0,
        http_requests: 0,
        errors: 0
      }
    )

    queue_signal = result.dig("signals", "queue_wait_ms")
    reason_codes = result.fetch("findings").map { |finding| finding.fetch("reason_code") }

    assert queue_signal.fetch("regression")
    assert_includes reason_codes, "QUEUE_WAIT_REGRESSION"
    assert_equal "review", result.fetch("merge_recommendation")
    assert_equal "queue_bound", result.dig("runtime_diagnosis", "async", "candidate", "classification")
    assert_equal "worker_bound", result.dig("runtime_diagnosis", "async", "baseline", "classification")
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

  def runtime_observation(signal, value, producer_id)
    {
      "signal" => signal,
      "payload" => { "value" => value },
      "producer_kind" => "active_job",
      "producer_name" => "ProbeJob",
      "producer_id" => producer_id
    }
  end
end
