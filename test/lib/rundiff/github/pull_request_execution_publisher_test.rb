require "test_helper"

class RunDiffGithubPullRequestExecutionPublisherTest < ActiveSupport::TestCase
  class TestPublisher < RunDiff::Github::PullRequestExecutionPublisher
    attr_accessor :check_override, :comment_override

    private

    def check_publisher
      check_override
    end

    def comment_publisher
      comment_override
    end
  end

  class CheckRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def upsert(**attributes)
      @calls << attributes
      :created
    end
  end

  class CommentRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def upsert(**attributes)
      @calls << attributes
      :created
    end
  end

  Execution = Data.define(:context, :candidate_sha, :execution_id)

  test "uses the product-facing Behavioral Review check name by default" do
    assert_equal(
      "RunDiff / Behavioral Review",
      RunDiff::Github::PullRequestExecutionPublisher::DEFAULT_CHECK_NAME
    )
  end

  test "uses the production RunDiff bot login by default" do
    assert_equal(
      "rundiff-checks[bot]",
      RunDiff::Github::PullRequestExecutionPublisher::DEFAULT_BOT_LOGIN
    )
  end

  test "publishes infrastructure failure as a failed rerunnable check" do
    check = CheckRecorder.new
    comment = CommentRecorder.new
    publisher = TestPublisher.new(token: "installation-token")
    publisher.check_override = check
    publisher.comment_override = comment

    result = publisher.infra_failure(
      execution: execution,
      error_class: "RunDiff::Executor::HttpAdapter::Error",
      error_message: "Remote executor returned HTTP 401"
    )

    assert_equal({ check: :created, comment: :created }, result)
    assert_equal 1, check.calls.size
    assert_equal 1, comment.calls.size

    check_call = check.calls.first
    comment_call = comment.calls.first

    assert_equal "failure", check_call.fetch(:conclusion)
    assert_equal "github-execution", check_call.fetch(:external_id)
    assert_match "INFRA_FAILURE", check_call.fetch(:summary)
    assert_match "not a product regression", check_call.fetch(:summary)
    assert_match "Remote executor returned HTTP 401", check_call.fetch(:summary)
    assert_match "INFRA_FAILURE", comment_call.fetch(:body)
    assert_match "Remote executor returned HTTP 401", comment_call.fetch(:body)
  end

  private

  def execution
    Execution.new(
      context: {
        "repository" => "rundiff/rundiff",
        "pull_request_number" => 40
      },
      candidate_sha: "head-sha",
      execution_id: "github-execution"
    )
  end
end
