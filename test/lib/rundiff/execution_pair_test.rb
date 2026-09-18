require "test_helper"

class RunDiffExecutionPairTest < ActiveSupport::TestCase
  test "composes two real executions into the GitHub-compatible payload" do
    baseline = execution(id: "main", sql_queries: 14)
    candidate = execution(id: "candidate", sql_queries: 19)

    payload = RunDiff::ExecutionPair.call(baseline:, candidate:)

    assert_equal "run-1", payload.fetch("run_id")
    assert_equal "scenario-1", payload.fetch("scenario_id")
    assert_equal "main", payload.dig("executions", "baseline", "id")
    assert_equal "candidate", payload.dig("executions", "candidate", "id")
    assert_equal "DATABASE_QUERY_REGRESSION", payload.dig("result", "findings", 0, "reason_code")
    assert_equal "block", payload.dig("result", "merge_recommendation")
  end

  test "attaches trusted explicit or unambiguous runtime sources only when the path changed" do
    %w[explicit runtime].each do |confidence|
      baseline = execution(id: "main", sql_queries: 14)
      candidate = execution(id: "candidate", sql_queries: 19).merge(
        "attributions" => {
          "sql_queries" => [ source(confidence:) ]
        }
      )

      trusted = RunDiff::ExecutionPair.call(
        baseline:,
        candidate:,
        changed_paths: [ "app/controllers/demo/behavior_controller.rb" ]
      )
      untrusted = RunDiff::ExecutionPair.call(
        baseline:,
        candidate:,
        changed_paths: [ "README.md" ]
      )

      assert_equal confidence, trusted.dig("result", "findings", 0, "source", "confidence")
      assert_nil untrusted.dig("result", "findings", 0, "source")
    end
  end

  test "prefers explicit attribution when runtime attribution is ambiguous" do
    baseline = execution(id: "main", sql_queries: 14)
    candidate = execution(id: "candidate", sql_queries: 19).merge(
      "attributions" => {
        "sql_queries" => [
          source(confidence: "runtime"),
          source(confidence: "runtime", line: 30),
          source(confidence: "explicit", line: 40)
        ]
      }
    )

    payload = RunDiff::ExecutionPair.call(
      baseline:,
      candidate:,
      changed_paths: [ "app/controllers/demo/behavior_controller.rb" ]
    )

    assert_equal 40, payload.dig("result", "findings", 0, "source", "start_line")
    assert_equal "explicit", payload.dig("result", "findings", 0, "source", "confidence")
  end

  test "does not localize an ambiguous runtime source" do
    baseline = execution(id: "main", sql_queries: 14)
    candidate = execution(id: "candidate", sql_queries: 19).merge(
      "attributions" => {
        "sql_queries" => [
          source(confidence: "runtime"),
          source(confidence: "runtime", line: 30)
        ]
      }
    )

    payload = RunDiff::ExecutionPair.call(
      baseline:,
      candidate:,
      changed_paths: [ "app/controllers/demo/behavior_controller.rb" ]
    )

    assert_nil payload.dig("result", "findings", 0, "source")
  end

  test "rejects inferred source confidence" do
    baseline = execution(id: "main", sql_queries: 14)
    candidate = execution(id: "candidate", sql_queries: 19).merge(
      "attributions" => {
        "sql_queries" => [ source(confidence: "inferred") ]
      }
    )

    payload = RunDiff::ExecutionPair.call(
      baseline:,
      candidate:,
      changed_paths: [ "app/controllers/demo/behavior_controller.rb" ]
    )

    assert_nil payload.dig("result", "findings", 0, "source")
  end

  test "rejects executions from different scenarios" do
    baseline = execution(id: "main", sql_queries: 14)
    candidate = execution(id: "candidate", sql_queries: 14).merge("scenario_id" => "other")

    error = assert_raises(ArgumentError) do
      RunDiff::ExecutionPair.call(baseline:, candidate:)
    end

    assert_equal "baseline and candidate must share run_id and scenario_id", error.message
  end

  private

  def source(confidence:, line: 20)
    {
      "path" => "app/controllers/demo/behavior_controller.rb",
      "start_line" => line,
      "end_line" => line,
      "confidence" => confidence
    }
  end

  def execution(id:, sql_queries:)
    {
      "id" => id,
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
end
