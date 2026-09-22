require "test_helper"

class RunDiffFindingIdentityTest < ActiveSupport::TestCase
  test "fingerprint is stable across reruns of the same logical finding" do
    first = finding
    second = finding

    RunDiff::FindingIdentity.enrich!(
      finding: first,
      scenario_id: "checkout.create-order",
      baseline: execution("base-a"),
      candidate: execution("head-a")
    )
    RunDiff::FindingIdentity.enrich!(
      finding: second,
      scenario_id: "checkout.create-order",
      baseline: execution("base-b"),
      candidate: execution("head-b")
    )

    assert_equal first.fetch("fingerprint"), second.fetch("fingerprint")
  end

  test "fingerprint changes when scenario or signal identity changes" do
    request_cpu = finding(
      rule_id: "resource.cpu.time.regression",
      signal: "thread_cpu_ms"
    )
    worker_cpu = finding(
      rule_id: "resource.cpu.time.regression",
      signal: "worker_thread_cpu_ms"
    )

    RunDiff::FindingIdentity.enrich!(
      finding: request_cpu,
      scenario_id: "checkout",
      baseline: execution("base"),
      candidate: execution("head")
    )
    RunDiff::FindingIdentity.enrich!(
      finding: worker_cpu,
      scenario_id: "checkout",
      baseline: execution("base"),
      candidate: execution("head")
    )

    refute_equal request_cpu.fetch("fingerprint"), worker_cpu.fetch("fingerprint")
  end

  test "evidence refs point to exact baseline and candidate measurements" do
    enriched = RunDiff::FindingIdentity.enrich!(
      finding: finding,
      scenario_id: "checkout.create-order",
      baseline: execution("baseline-17"),
      candidate: execution("candidate-31")
    )

    assert_equal(
      [
        {
          "kind" => "measurement",
          "role" => "baseline",
          "execution_id" => "baseline-17",
          "signal" => "sql_queries"
        },
        {
          "kind" => "measurement",
          "role" => "candidate",
          "execution_id" => "candidate-31",
          "signal" => "sql_queries"
        }
      ],
      enriched.fetch("evidence_refs")
    )
  end

  private

  def finding(rule_id: "database.query.count.regression", signal: "sql_queries")
    {
      "rule_id" => rule_id,
      "signal" => signal
    }
  end

  def execution(id)
    { "id" => id }
  end
end
