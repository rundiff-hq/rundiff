require "test_helper"

class RunDiffGithubCommentPublisherTest < ActiveSupport::TestCase
  class FakePublisher < RunDiff::Github::CommentPublisher
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    private

    def request(method, path, body: nil)
      @calls << { method:, path:, body: }
      response = @responses.fetch([ method, path ])
      response.respond_to?(:call) ? response.call(body) : response
    end
  end

  test "skips a stale run before reading or updating comments" do
    publisher = FakePublisher.new(
      [ :get, "/repos/rundiff/rundiff/pulls/2" ] => { "head" => { "sha" => "new-head" } }
    )

    action = publisher.upsert(
      repository: "rundiff/rundiff",
      pr_number: 2,
      body: "report",
      author: "github-actions[bot]",
      expected_head_sha: "old-head"
    )

    assert_equal :stale, action
    assert_equal 1, publisher.calls.size
  end

  test "updates the owned durable comment when the run matches the current head" do
    comments_path = "/repos/rundiff/rundiff/issues/2/comments?per_page=100"
    publisher = FakePublisher.new(
      [ :get, "/repos/rundiff/rundiff/pulls/2" ] => { "head" => { "sha" => "current-head" } },
      [ :get, comments_path ] => [
        {
          "id" => 42,
          "body" => RunDiff::Github::CommentRenderer::MARKER,
          "user" => { "login" => "github-actions[bot]" }
        }
      ],
      [ :patch, "/repos/rundiff/rundiff/issues/comments/42" ] => {}
    )

    action = publisher.upsert(
      repository: "rundiff/rundiff",
      pr_number: 2,
      body: "updated report",
      author: "github-actions[bot]",
      expected_head_sha: "current-head"
    )

    assert_equal :updated, action
    assert_equal :patch, publisher.calls.last.fetch(:method)
    assert_equal({ body: "updated report" }, publisher.calls.last.fetch(:body))
  end
end
