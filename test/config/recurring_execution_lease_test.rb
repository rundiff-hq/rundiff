require "test_helper"
require "yaml"

class RecurringExecutionLeaseTest < ActiveSupport::TestCase
  test "production schedules the execution lease reaper every minute" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    entry = config.fetch("production").fetch("reap_expired_rundiff_executions")

    assert_equal "GithubPullRequestExecutionLeaseReaperJob", entry.fetch("class")
    assert_equal "every minute", entry.fetch("schedule")
  end
end
