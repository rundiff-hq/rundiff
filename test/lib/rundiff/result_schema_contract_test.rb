require "test_helper"
require "json"

class RunDiffResultSchemaContractTest < ActiveSupport::TestCase
  SCHEMA = Rails.root.join("schemas/rundiff-result-v1.schema.json")

  test "documents blocking and confidence metadata for findings" do
    schema = JSON.parse(SCHEMA.read)
    finding = schema.dig("properties", "findings", "items", "properties")

    assert_equal "boolean", finding.dig("blocking", "type")
    assert_equal(
      %w[deterministic single_sample_timing],
      finding.dig("confidence", "enum")
    )
  end

  test "keeps new confidence fields optional for v1 compatibility" do
    schema = JSON.parse(SCHEMA.read)
    finding_items = schema.dig("properties", "findings", "items")

    refute_includes Array(finding_items["required"]), "blocking"
    refute_includes Array(finding_items["required"]), "confidence"
    assert_equal true, finding_items.fetch("additionalProperties")
  end
end
