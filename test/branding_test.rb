require "test_helper"

class RunDiffBrandingTest < ActiveSupport::TestCase
  LEGACY_TOKENS = [
    "Ply" + "wo",
    "PLY" + "WO",
    "ply" + "wo"
  ].freeze

  test "repository contains no legacy product identifiers" do
    tracked_paths = IO.popen([ "git", "ls-files", "-z" ], &:read).split("\0").reject(&:empty?)
    violations = []

    tracked_paths.each do |path|
      LEGACY_TOKENS.each do |token|
        violations << "#{path}: path contains #{token.inspect}" if path.include?(token)
      end

      content = File.binread(path).force_encoding(Encoding::UTF_8)
      next unless content.valid_encoding?

      LEGACY_TOKENS.each do |token|
        violations << "#{path}: content contains #{token.inspect}" if content.include?(token)
      end
    end

    assert_empty violations, "Legacy product identifiers remain:\n#{violations.join("\n")}"
  end
end
