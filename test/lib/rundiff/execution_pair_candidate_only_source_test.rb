require "test_helper"

class RunDiffExecutionPairCandidateOnlySourceTest < ActiveSupport::TestCase
  test "localizes the runtime source that appears only in the candidate" do
    baseline = execution(
      http_requests: 2,
      attributions: [ source(5) ]
    )
    candidate = execution(
      http_requests: 3,
      attributions: [ source(5), source(6) ]
    )

    payload = RunDiff::ExecutionPair.call(
      baseline:,
      candidate:,
      changed_paths: [ "app/jobs/demo_async_evidence_job.rb" ]
    )

    finding = payload.fetch("result").fetch("findings").find do |entry|
      entry.fetch("signal") == "http_requests"
    end

    assert_equal "NETWORK_BEHAVIOR_CHANGED", finding.fetch("reason_code")
    assert_equal "allow", payload.dig("result", "merge_recommendation")
    assert_equal "WARNING", finding.fetch("finding_severity")
    assert_equal source(6), finding.fetch("source")
  end

  private

  def execution(http_requests:, attributions:)
    {
      "id" => "subject",
      "run_id" => "run-1",
      "scenario_id" => "scenario-1",
      "measurements" => {
        "duration_ms" => 25,
        "sql_queries" => 15,
        "background_jobs" => 1,
        "emails" => 2,
        "http_requests" => http_requests,
        "errors" => 0
      },
      "attributions" => {
        "http_requests" => attributions
      }
    }
  end

  def source(line)
    {
      "path" => "app/jobs/demo_async_evidence_job.rb",
      "start_line" => line,
      "end_line" => line,
      "confidence" => "runtime"
    }
  end
end
