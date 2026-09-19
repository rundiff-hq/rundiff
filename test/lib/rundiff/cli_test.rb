require "test_helper"
require "json"
require "stringio"
require "tempfile"
require Rails.root.join("lib/rundiff/cli").to_s

class RunDiffCliTest < ActiveSupport::TestCase
  test "renders a blocking Behavioral Review in the terminal" do
    with_review_payload do |path|
      stdout = StringIO.new
      stderr = StringIO.new

      status = RunDiff::CLI.new(
        [ "review", "--input", path, "--color", "never" ],
        stdout:,
        stderr:
      ).run

      assert_equal 0, status
      assert_empty stderr.string
      assert_includes stdout.string, "RunDiff Behavioral Review"
      assert_includes stdout.string, "✕ BLOCK"
      assert_includes stdout.string, "SQL queries"
      assert_includes stdout.string, "DATABASE_QUERY_REGRESSION"
      assert_includes stdout.string, "Functional scenario: PASSED"
      assert_includes stdout.string, "Baseline"
      assert_includes stdout.string, "Candidate"
    end
  end

  test "can fail a shell command when the review blocks" do
    with_review_payload do |path|
      status = RunDiff::CLI.new(
        [ "review", "--input", path, "--color", "never", "--fail-on-block" ],
        stdout: StringIO.new,
        stderr: StringIO.new
      ).run

      assert_equal 1, status
    end
  end

  test "renders the same review payload as GitHub-flavored markdown" do
    with_review_payload do |path|
      stdout = StringIO.new

      status = RunDiff::CLI.new(
        [ "review", "--input", path, "--format", "markdown" ],
        stdout:,
        stderr: StringIO.new
      ).run

      assert_equal 0, status
      assert_includes stdout.string, "RunDiff Behavioral Review"
      assert_includes stdout.string, "**BLOCK** - Tests passed, but runtime behavior changed."
      assert_includes stdout.string, "### What changed"
      assert_includes stdout.string, "`DATABASE_QUERY_REGRESSION`"
    end
  end

  test "accepts an executor result envelope" do
    payload = review_payload
    envelope = {
      "schema_version" => "1",
      "status" => "succeeded",
      "payload" => payload,
      "error_class" => nil,
      "error_message" => nil
    }

    Tempfile.create([ "rundiff-review-envelope", ".json" ]) do |file|
      file.write(JSON.pretty_generate(envelope))
      file.flush
      stdout = StringIO.new

      status = RunDiff::CLI.new(
        [ "review", "--input", file.path, "--format", "json" ],
        stdout:,
        stderr: StringIO.new
      ).run

      assert_equal 0, status
      parsed = JSON.parse(stdout.string)
      assert_equal "block", parsed.dig("result", "merge_recommendation")
      assert_equal "scenario.review", parsed.fetch("scenario_id")
    end
  end

  private

  def with_review_payload
    Tempfile.create([ "rundiff-review", ".json" ]) do |file|
      file.write(JSON.pretty_generate(review_payload))
      file.flush
      yield file.path
    end
  end

  def review_payload
    RunDiff::ExecutionPair.call(
      baseline: execution(ref: "main", sha: "1111111111111111", sql_queries: 2),
      candidate: execution(ref: "feature/sql", sha: "2222222222222222", sql_queries: 8)
    )
  end

  def execution(ref:, sha:, sql_queries:)
    {
      "run_id" => "run-review",
      "scenario_id" => "scenario.review",
      "subject" => "git-comparison",
      "ref" => ref,
      "sha" => sha,
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
