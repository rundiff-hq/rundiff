require "test_helper"
require Rails.root.join("lib/rundiff/terminal_renderer").to_s

class RunDiffTerminalRendererTest < ActiveSupport::TestCase
  test "renders an allowed review compactly" do
    payload = RunDiff::ExecutionPair.call(
      baseline: execution(sql_queries: 2),
      candidate: execution(sql_queries: 2)
    )

    output = RunDiff::TerminalRenderer.call(payload:, color: :never)

    assert_includes output, "✓ ALLOW"
    assert_includes output, "No behavioral regression detected."
    assert_includes output, "SQL queries"
    assert_not_includes output, "Finding"
  end

  test "supports ANSI color for an interactive presentation" do
    payload = RunDiff::ExecutionPair.call(
      baseline: execution(sql_queries: 2),
      candidate: execution(sql_queries: 8)
    )

    output = RunDiff::TerminalRenderer.call(payload:, color: :always)

    assert_includes output, "\e[31;1m✕ BLOCK\e[0m"
    assert_includes output, "DATABASE_QUERY_REGRESSION"
  end

  private

  def execution(sql_queries:)
    {
      "run_id" => "run-terminal",
      "scenario_id" => "scenario.terminal",
      "ref" => "main",
      "sha" => "abcdef1234567890",
      "status" => "passed",
      "correlation_confirmed" => true,
      "measurements" => {
        "duration_ms" => 100,
        "sql_queries" => sql_queries,
        "background_jobs" => 1,
        "emails" => 0,
        "http_requests" => 0,
        "errors" => 0
      }
    }
  end
end
