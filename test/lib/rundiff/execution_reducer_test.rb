require "test_helper"

class RunDiffExecutionReducerTest < ActiveSupport::TestCase
  test "folds durable worker observations into one execution" do
    execution = {
      "id" => "candidate",
      "measurements" => {
        "duration_ms" => 25.0,
        "process_cpu_ms" => 6.0,
        "thread_cpu_ms" => 5.0,
        "sql_queries" => 14,
        "background_jobs" => 1,
        "emails" => 1,
        "http_requests" => 1,
        "errors" => 0
      },
      "attributions" => {
        "http_requests" => [ source("app/controllers/demo/behavior_controller.rb", 30) ]
      },
      "durable_observations" => [
        observation("sql_queries", "app/jobs/demo_async_evidence_job.rb", 3),
        observation("emails", "app/jobs/demo_async_evidence_job.rb", 4),
        observation("http_requests", "app/jobs/demo_async_evidence_job.rb", 5),
        runtime_observation("worker_wall_ms", 50.0),
        runtime_observation("worker_wall_ms", 30.0),
        runtime_observation("worker_process_cpu_ms", 12.0),
        runtime_observation("worker_thread_cpu_ms", 10.0)
      ]
    }

    reduced = RunDiff::ExecutionReducer.call(execution:)

    assert_equal 15, reduced.dig("measurements", "sql_queries")
    assert_equal 1, reduced.dig("measurements", "background_jobs")
    assert_equal 2, reduced.dig("measurements", "emails")
    assert_equal 2, reduced.dig("measurements", "http_requests")
    assert_equal 0, reduced.dig("measurements", "errors")
    assert_equal 25.0, reduced.dig("measurements", "duration_ms")
    assert_equal 80.0, reduced.dig("measurements", "worker_wall_ms")
    assert_equal 12.0, reduced.dig("measurements", "worker_process_cpu_ms")
    assert_equal 10.0, reduced.dig("measurements", "worker_thread_cpu_ms")
    assert_equal "wait_bound", reduced.dig("runtime_profile", "request", "classification")
    assert_equal 20.0, reduced.dig("runtime_profile", "request", "cpu_ratio_percent")
    assert_equal "wait_bound", reduced.dig("runtime_profile", "worker", "classification")
    assert_equal 12.5, reduced.dig("runtime_profile", "worker", "cpu_ratio_percent")
    assert_equal 7, reduced.dig("evidence", "durable_observations")
    assert_equal(
      [
        source("app/controllers/demo/behavior_controller.rb", 30),
        source("app/jobs/demo_async_evidence_job.rb", 5)
      ],
      reduced.dig("attributions", "http_requests")
    )
  end

  test "counts durable runtime errors" do
    execution = {
      "measurements" => { "errors" => 0 },
      "durable_observations" => [ { "signal" => "errors", "payload" => { "error_class" => "RuntimeError" } } ]
    }

    reduced = RunDiff::ExecutionReducer.call(execution:)

    assert_equal 1, reduced.dig("measurements", "errors")
  end

  private

  def observation(signal, path, line)
    source(path, line).merge(
      "signal" => signal,
      "producer_kind" => "active_job",
      "producer_name" => "DemoAsyncEvidenceJob",
      "producer_id" => "job-1"
    )
  end

  def runtime_observation(signal, value)
    {
      "signal" => signal,
      "payload" => { "value" => value },
      "producer_kind" => "active_job",
      "producer_name" => "DemoAsyncEvidenceJob",
      "producer_id" => "job-1"
    }
  end

  def source(path, line)
    {
      "path" => path,
      "start_line" => line,
      "end_line" => line,
      "confidence" => "runtime"
    }
  end
end
