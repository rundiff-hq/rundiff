require "test_helper"
require "json"

class RunDiffExecutorProtocolV1Test < ActiveSupport::TestCase
  FIXTURE_ROOT = Rails.root.join("protocol", "executor", "v1", "fixtures")
  SCHEMA_ROOT = Rails.root.join("protocol", "executor", "v1")

  test "request fixture round-trips through the Ruby v1 contract" do
    payload = JSON.parse(FIXTURE_ROOT.join("request.json").read)

    assert_equal payload, RunDiff::Executor::Request.from_h(payload).to_h
  end

  test "result fixtures round-trip through the Ruby v1 contract" do
    %w[result-allow.json result-block.json result-failure.json].each do |name|
      payload = JSON.parse(FIXTURE_ROOT.join(name).read)

      assert_equal payload, RunDiff::Executor::Result.from_h(payload).to_h
    end
  end

  test "canonical schemas declare protocol v1" do
    request_schema = JSON.parse(SCHEMA_ROOT.join("request.schema.json").read)
    result_schema = JSON.parse(SCHEMA_ROOT.join("result.schema.json").read)

    assert_equal "1", request_schema.dig("properties", "schema_version", "const")
    assert_equal "1", result_schema.dig("properties", "schema_version", "const")
  end
end
