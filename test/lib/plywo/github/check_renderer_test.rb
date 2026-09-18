require "test_helper"

class PlywoGithubCheckRendererTest < ActiveSupport::TestCase
  test "maps an allowed result to a successful GitHub check" do
    rendered = Plywo::Github::CheckRenderer.call(
      payload: pair_payload(sql_queries: 14),
      run_url: "https://github.com/rundiff-hq/rundiff/actions/runs/1"
    )

    assert_equal "RunDiff / Behavioral Diff", rendered.fetch("name")
    assert_equal "success", rendered.fetch("conclusion")
    assert_equal "No behavioral regression detected", rendered.fetch("title")
    assert_includes rendered.fetch("summary"), "**ALLOW**"
    assert_includes rendered.fetch("summary"), "[Open execution](https://github.com/rundiff-hq/rundiff/actions/runs/1)"
    assert_empty rendered.fetch("annotations")
  end

  test "renders a source-localized annotation for a trusted finding" do
    payload = pair_payload(
      sql_queries: 18,
      attributions: {
        "sql_queries" => [
          {
            "path" => "app/controllers/demo/behavior_controller.rb",
            "start_line" => 20,
            "end_line" => 20,
            "confidence" => "explicit"
          }
        ]
      },
      changed_paths: [ "app/controllers/demo/behavior_controller.rb" ]
    )
    rendered = Plywo::Github::CheckRenderer.call(payload:)
    annotation = rendered.fetch("annotations").first

    assert_equal "failure", rendered.fetch("conclusion")
    assert_equal "app/controllers/demo/behavior_controller.rb", annotation.fetch("path")
    assert_equal 20, annotation.fetch("start_line")
    assert_equal "failure", annotation.fetch("annotation_level")
    assert_includes annotation.fetch("message"), "14 to 18"
  end

  test "renders async regression attribution in the check summary" do
    rendered = Plywo::Github::CheckRenderer.call(payload: async_regression_payload)
    summary = rendered.fetch("summary")

    assert_equal "neutral", rendered.fetch("conclusion")
    assert_includes summary, "Async change attribution"
    assert_includes summary, "**Regression source:** enqueue-to-start stage"
    assert_includes summary, "Enqueue → worker start | +264.1 ms | 100.0%"
    assert_includes summary, "Worker runtime | unchanged | 0.0%"
  end

  private

  def pair_payload(sql_queries:, attributions: {}, changed_paths: [])
    Plywo::ExecutionPair.call(
      baseline: execution(sql_queries: 14),
      candidate: execution(sql_queries:).merge("attributions" => attributions),
      changed_paths:
    )
  end

  def async_regression_payload
    Plywo::ExecutionPair.call(
      baseline: async_execution(queue_wait_ms: 137.5),
      candidate: async_execution(queue_wait_ms: 401.6)
    )
  end

  def execution(sql_queries:)
    {
      "run_id" => "run-1",
      "scenario_id" => "scenario-1",
      "status" => "passed",
      "correlation_confirmed" => true,
      "measurements" => {
        "duration_ms" => 100,
        "sql_queries" => sql_queries,
        "background_jobs" => 1,
        "emails" => 1,
        "http_requests" => 1,
        "errors" => 0
      }
    }
  end

  def async_execution(queue_wait_ms:)
    execution(sql_queries: 17).merge(
      "measurements" => {
        "duration_ms" => 50.0,
        "thread_cpu_ms" => 20.0,
        "queue_wait_ms" => queue_wait_ms,
        "worker_wall_ms" => 0.1,
        "worker_thread_cpu_ms" => 0.1,
        "sql_queries" => 17,
        "background_jobs" => 1,
        "emails" => 1,
        "http_requests" => 1,
        "errors" => 0
      }
    )
  end
end
