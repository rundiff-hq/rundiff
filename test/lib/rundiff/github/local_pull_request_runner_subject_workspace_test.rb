require "test_helper"
require "pathname"
require "tmpdir"

class RunDiffGithubLocalPullRequestRunnerSubjectWorkspaceTest < ActiveSupport::TestCase
  class RecordingIdentity
    attr_reader :events

    def initialize
      @events = []
    end

    def prepare_tree(path)
      events << [ :prepare_tree, Pathname(path).basename.to_s ]
    end

    def prepare_output(path)
      events << [ :prepare_output, Pathname(path).basename.to_s ]
    end

    def seal_output(path)
      events << [ :seal_output, Pathname(path).basename.to_s ]
    end

    def seal_tree(path)
      events << [ :seal_tree, Pathname(path).basename.to_s ]
    end
  end

  test "activates and seals one subject workspace in deterministic order" do
    identity = RecordingIdentity.new
    runner = RunDiff::Github::LocalPullRequestRunner.allocate
    runner.instance_variable_set(:@execution_identity, identity)

    Dir.mktmpdir do |directory|
      root = Pathname(directory).join("base")
      root.mkdir
      output = Pathname(directory).join("base.json")

      runner.send(:with_subject_workspace, root:, output:) do
        identity.events << [ :capture, "base" ]
      end
    end

    assert_equal(
      [
        [ :prepare_tree, "base" ],
        [ :prepare_output, "base.json" ],
        [ :capture, "base" ],
        [ :seal_output, "base.json" ],
        [ :seal_tree, "base" ]
      ],
      identity.events
    )
  end

  test "seals output and workspace when subject execution fails" do
    identity = RecordingIdentity.new
    runner = RunDiff::Github::LocalPullRequestRunner.allocate
    runner.instance_variable_set(:@execution_identity, identity)

    assert_raises(RuntimeError) do
      Dir.mktmpdir do |directory|
        root = Pathname(directory).join("candidate")
        root.mkdir
        output = Pathname(directory).join("candidate.json")

        runner.send(:with_subject_workspace, root:, output:) do
          identity.events << [ :capture, "candidate" ]
          raise "capture failed"
        end
      end
    end

    assert_equal(
      [
        [ :prepare_tree, "candidate" ],
        [ :prepare_output, "candidate.json" ],
        [ :capture, "candidate" ],
        [ :seal_output, "candidate.json" ],
        [ :seal_tree, "candidate" ]
      ],
      identity.events
    )
  end
end
