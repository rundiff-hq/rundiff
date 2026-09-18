require "test_helper"
require "tmpdir"

class RunDiffSubjectRailsCaptureRuntimeTest < ActiveSupport::TestCase
  test "uses portable capture for a normal Rails repository" do
    Dir.mktmpdir do |directory|
      runtime = RunDiff::Subject::RailsCaptureRuntime.new

      assert_equal "tool_owned_portable_rails", runtime.mode_for(root: directory)
      assert_equal Rails.root.join("script", "rundiff_capture_portable_rails.rb"),
        runtime.script_for(root: directory, tool_root: Rails.root)
    end
  end

  test "keeps rich capture for a subject that explicitly owns RunDiff runtime" do
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      RunDiff::Subject::RailsCaptureRuntime::SUBJECT_OWNED_MARKERS.each do |relative_path|
        path = root.join(relative_path)
        FileUtils.mkdir_p(path.dirname)
        path.write("# marker\n")
      end

      runtime = RunDiff::Subject::RailsCaptureRuntime.new

      assert_equal "subject_owned_rails", runtime.mode_for(root:)
      assert_equal Rails.root.join("script", "rundiff_capture_subject.rb"),
        runtime.script_for(root:, tool_root: Rails.root)
    end
  end
end
