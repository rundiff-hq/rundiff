require "test_helper"

class RunDiffQueueStageExecutionReducerTest < ActiveSupport::TestCase
  test "folds max queue stage timings from durable worker observations" do
    execution = {
      "measurements" => {
        "duration_ms" => 50.0,
        "thread_cpu_ms" => 20.0,
        "sql_queries" => 17,
        "background_jobs" => 1,
        "emails" => 1,
        "http_requests" => 1,
        "errors" => 0
      },
      "durable_observations" => [
        runtime_observation("queue_wait_ms", 410.0),
        runtime_observation("scheduled_delay_ms", 250.0),
        runtime_observation("dispatch_wait_ms", 160.0),
        runtime_observation("worker_wall_ms", 0.1),
        runtime_observation("worker_thread_cpu_ms", 0.1)
      ]
    }

    reduced = RunDiff::ExecutionReducer.call(execution:)

    assert_equal 410.0, reduced.dig("measurements", "queue_wait_ms")
    assert_equal 250.0, reduced.dig("measurements", "scheduled_delay_ms")
    assert_equal 160.0, reduced.dig("measurements", "dispatch_wait_ms")
    assert_equal 0.1, reduced.dig("measurements", "worker_wall_ms")
  end

  private

  def runtime_observation(signal, value)
    {
      "signal" => signal,
      "payload" => { "value" => value },
      "producer_kind" => "active_job",
      "producer_name" => "DemoNotificationJob",
      "producer_id" => "job-1"
    }
  end
end
