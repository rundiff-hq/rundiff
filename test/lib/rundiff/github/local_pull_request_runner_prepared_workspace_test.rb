require "test_helper"
require "pathname"
require "tmpdir"

class RunDiffGithubLocalPullRequestRunnerPreparedWorkspaceTest < ActiveSupport::TestCase
  Execution = Struct.new(:execution_id)

  test "uses Go-prepared worktree paths without allocating Ruby workspace" do
    Dir.mktmpdir do |directory|
      baseline = File.join(directory, "base")
      candidate = File.join(directory, "candidate")
      FileUtils.mkdir_p(baseline)
      FileUtils.mkdir_p(candidate)

      with_env(
        "RUNDIFF_PREPARED_BY" => "go",
        "RUNDIFF_PREPARED_WORKSPACE_ROOT" => directory,
        "RUNDIFF_PREPARED_BASELINE_ROOT" => baseline,
        "RUNDIFF_PREPARED_CANDIDATE_ROOT" => candidate
      ) do
        runner = RunDiff::Github::LocalPullRequestRunner.allocate
        paths = runner.send(
          :execution_paths,
          execution: Execution.new("github-prepared")
        )

        assert_equal Pathname(baseline), paths.fetch(:baseline_root)
        assert_equal Pathname(candidate), paths.fetch(:candidate_root)
        assert_equal Pathname(directory).join("base.json"), paths.fetch(:baseline_output)
        assert_equal Pathname(directory).join("candidate.json"), paths.fetch(:candidate_output)
        assert runner.send(:prepared_workspace?)
      end
    end
  end

  test "parses Go-prepared runtime environment by role" do
    with_env(
      "RUNDIFF_PREPARED_BASELINE_RUNTIME_ENV_JSON" => '{"BUNDLE_PATH":"/tmp/base"}',
      "RUNDIFF_PREPARED_CANDIDATE_RUNTIME_ENV_JSON" => '{"BUNDLE_PATH":"/tmp/candidate"}'
    ) do
      runner = RunDiff::Github::LocalPullRequestRunner.allocate

      assert_equal(
        { "BUNDLE_PATH" => "/tmp/base" },
        runner.send(:prepared_runtime_env, "base")
      )
      assert_equal(
        { "BUNDLE_PATH" => "/tmp/candidate" },
        runner.send(:prepared_runtime_env, "candidate")
      )
    end
  end

  private

  def with_env(values)
    previous = values.each_key.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
