require "test_helper"

class ExecutorLifecycleQueueTest < ActiveJob::TestCase
  test "lifecycle control jobs are isolated from the blocking executor queue" do
    assert_equal "default", RunDiffExecutorJob.new.queue_name
    assert_equal "control", GithubPullRequestExecutionHeartbeatJob.new.queue_name
    assert_equal "control", RunDiffExecutorCancellationJob.new.queue_name
    assert_equal "control", GithubPullRequestExecutionLeaseReaperJob.new.queue_name
    assert_equal "control", GithubPullRequestExecutionLeaseExpiryJob.new.queue_name
  end
end
