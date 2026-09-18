require "test_helper"

class PlywoGithubCommentRendererTest < ActiveSupport::TestCase
  test "renders a durable GitHub review comment with runtime evidence" do
    payload = Plywo::Demo::DogfoodRunner.call
    markdown = Plywo::Github::CommentRenderer.markdown(
      payload:,
      context: {
        repository: "rundiff-hq/rundiff",
        pr_number: 1,
        baseline_label: "dogfood baseline",
        baseline_sha: "synthetic",
        candidate_label: "bootstrap/rails-first-slice",
        candidate_sha: "abcdef123456",
        bootstrap_baseline: true
      }
    )

    assert_includes markdown, Plywo::Github::CommentRenderer::MARKER
    assert_includes markdown, "RunDiff · Behavioral Review"
    assert_includes markdown, "SQL queries"
    assert_includes markdown, "Merge recommendation: **BLOCK**"
    assert_includes markdown, "bootstrap dogfood run"
  end

  test "links real Git subjects and renders singular regression grammar" do
    payload = real_pair_payload
    markdown = Plywo::Github::CommentRenderer.markdown(
      payload:,
      context: {
        repository: "rundiff-hq/rundiff",
        pr_number: 2,
        baseline_label: "main",
        baseline_sha: "0123456789abcdef",
        candidate_label: "feature",
        candidate_sha: "fedcba9876543210",
        execution_mode: "exact Git worktrees + isolated PostgreSQL databases"
      }
    )

    assert_includes markdown, "1 regression · 1 high"
    assert_includes markdown, "[`01234567`](https://github.com/rundiff-hq/rundiff/commit/0123456789abcdef)"
    assert_includes markdown, "[`fedcba98`](https://github.com/rundiff-hq/rundiff/commit/fedcba9876543210)"
    assert_includes markdown, "[Source diff](https://github.com/rundiff-hq/rundiff/compare/0123456789abcdef...fedcba9876543210)"
    assert_includes markdown, "Evidence: exact Git worktrees + isolated PostgreSQL databases"
  end

  test "explains which async stage caused a regression for legacy evidence" do
    markdown = Plywo::Github::CommentRenderer.markdown(payload: async_regression_payload)

    assert_includes markdown, "Enqueue → worker start (aggregate)"
    assert_includes markdown, "enqueue-to-start dominates"
    assert_includes markdown, "Async change attribution"
    assert_includes markdown, "Regression source: enqueue-to-start stage"
    assert_includes markdown, "+264.1 ms"
    assert_includes markdown, "Worker runtime | unchanged | 0.0%"
  end

  private

  def real_pair_payload
    baseline = execution(sql_queries: 14)
    candidate = execution(sql_queries: 19)
    Plywo::ExecutionPair.call(baseline:, candidate:)
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
