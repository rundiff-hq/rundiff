require "test_helper"

class RunDiffGithubCheckPublisherTest < ActiveSupport::TestCase
  class FakePublisher < RunDiff::Github::CheckPublisher
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    private

    def request(method, path, body: nil)
      @calls << { method:, path:, body: }
      @responses.fetch([ method, path ], {})
    end
  end

  test "creates a check when the head has no RunDiff check" do
    list_path = "/repos/rundiff/rundiff/commits/head/check-runs?check_name=RunDiff+%2F+Behavioral+Diff&filter=latest"
    publisher = FakePublisher.new([ :get, list_path ] => { "check_runs" => [] })

    action = publisher.upsert(**attributes)

    assert_equal :created, action
    assert_equal :post, publisher.calls.last.fetch(:method)
    assert_equal "head", publisher.calls.last.dig(:body, :head_sha)
  end

  test "updates the existing RunDiff check on the same head" do
    list_path = "/repos/rundiff/rundiff/commits/head/check-runs?check_name=RunDiff+%2F+Behavioral+Diff&filter=latest"
    publisher = FakePublisher.new(
      [ :get, list_path ] => { "check_runs" => [ { "id" => 42, "name" => "RunDiff / Behavioral Diff" } ] }
    )

    action = publisher.upsert(**attributes)

    assert_equal :updated, action
    assert_equal :patch, publisher.calls.last.fetch(:method)
    assert_equal "/repos/rundiff/rundiff/check-runs/42", publisher.calls.last.fetch(:path)
  end

  private

  def attributes
    {
      repository: "rundiff/rundiff",
      head_sha: "head",
      name: "RunDiff / Behavioral Diff",
      external_id: "run-1",
      details_url: "https://github.com/rundiff/rundiff/actions/runs/1",
      conclusion: "success",
      title: "No behavioral regression detected",
      summary: "ALLOW"
    }
  end
end

class RunDiffGithubCheckNameIsolationTest < ActiveSupport::TestCase
  test "CI dogfood check name is distinct from production behavioral review" do
    workflow = File.read(Rails.root.join(".github/workflows/ci.yml"))

    assert_includes workflow, "RUNDIFF_CHECK_NAME: RunDiff / CI Dogfood"
  end
end
