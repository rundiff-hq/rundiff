require "test_helper"
require "tmpdir"

class RunDiffSubjectJavascriptDependenciesBootstrapTest < ActiveSupport::TestCase
  class RecordingRunner
    attr_reader :calls

    def initialize(after_call: nil, error: nil)
      @after_call = after_call
      @error = error
      @calls = []
    end

    def call(env:, command:, chdir:)
      @calls << { env:, command:, chdir: }
      @after_call&.call(Pathname(chdir))
      raise @error if @error

      ""
    end
  end

  test "uses reproducible install commands for supported package managers" do
    cases = [
      [ "npm", "package-lock.json", nil, %w[npm ci] ],
      [ "pnpm", "pnpm-lock.yaml", nil, %w[pnpm install --frozen-lockfile] ],
      [ "yarn", "yarn.lock", "classic", %w[yarn install --frozen-lockfile] ],
      [ "yarn", "yarn.lock", "berry", %w[yarn install --immutable] ],
      [ "bun", "bun.lock", nil, %w[bun install --frozen-lockfile] ]
    ]

    cases.each do |manager, lockfile, yarn_generation, expected_command|
      with_subject(lockfile:) do |root|
        runner = RecordingRunner.new
        bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: runner)

        environment = bootstrap.call(
          root:,
          step: dependency_step(manager:, lockfile:, yarn_generation:)
        )

        assert_equal({}, environment)
        assert_equal expected_command, runner.calls.sole.fetch(:command)
        assert_equal({}, runner.calls.sole.fetch(:env))
        assert_equal root.to_s, runner.calls.sole.fetch(:chdir)
      end
    end
  end

  test "fails closed if dependency installation mutates the committed lockfile" do
    with_subject(lockfile: "pnpm-lock.yaml") do |root|
      runner = RecordingRunner.new(
        after_call: ->(path) { path.join("pnpm-lock.yaml").write("mutated\n") }
      )
      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: runner)

      error = assert_raises(RunDiff::Subject::JavascriptDependenciesBootstrap::Error) do
        bootstrap.call(root:, step: dependency_step(manager: "pnpm", lockfile: "pnpm-lock.yaml"))
      end

      assert_equal "JavaScript dependency bootstrap mutated committed pnpm-lock.yaml", error.message
    end
  end

  test "checks committed files even when the install command fails" do
    with_subject(lockfile: "pnpm-lock.yaml") do |root|
      runner = RecordingRunner.new(
        after_call: ->(path) { path.join("pnpm-lock.yaml").write("mutated-before-failure\n") },
        error: RuntimeError.new("install failed")
      )
      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: runner)

      error = assert_raises(RunDiff::Subject::JavascriptDependenciesBootstrap::Error) do
        bootstrap.call(root:, step: dependency_step(manager: "pnpm", lockfile: "pnpm-lock.yaml"))
      end

      assert_equal "JavaScript dependency bootstrap mutated committed pnpm-lock.yaml", error.message
    end
  end

  test "fails closed if dependency installation mutates package.json" do
    with_subject(lockfile: "package-lock.json") do |root|
      runner = RecordingRunner.new(
        after_call: ->(path) { path.join("package.json").write("{\"mutated\":true}\n") }
      )
      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: runner)

      error = assert_raises(RunDiff::Subject::JavascriptDependenciesBootstrap::Error) do
        bootstrap.call(root:, step: dependency_step(manager: "npm", lockfile: "package-lock.json"))
      end

      assert_equal "JavaScript dependency bootstrap mutated committed package.json", error.message
    end
  end

  test "rejects a lockfile that does not belong to the selected manager" do
    with_subject(lockfile: "pnpm-lock.yaml") do |root|
      runner = RecordingRunner.new
      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: runner)

      error = assert_raises(RunDiff::Subject::JavascriptDependenciesBootstrap::Error) do
        bootstrap.call(root:, step: dependency_step(manager: "npm", lockfile: "pnpm-lock.yaml"))
      end

      assert_equal(
        'JavaScript package manager npm requires one of package-lock.json; received "pnpm-lock.yaml"',
        error.message
      )
      assert_empty runner.calls
    end
  end

  test "requires deterministic Yarn generation evidence" do
    with_subject(lockfile: "yarn.lock") do |root|
      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: RecordingRunner.new)

      error = assert_raises(RunDiff::Subject::JavascriptDependenciesBootstrap::Error) do
        bootstrap.call(root:, step: dependency_step(manager: "yarn", lockfile: "yarn.lock"))
      end

      assert_equal "Yarn dependency bootstrap requires deterministic yarn_generation evidence", error.message
    end
  end

  test "requires package.json and the committed lockfile before running" do
    Dir.mktmpdir("rundiff-js-bootstrap-") do |directory|
      root = Pathname(directory)
      runner = RecordingRunner.new
      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner: runner)

      error = assert_raises(RunDiff::Subject::JavascriptDependenciesBootstrap::Error) do
        bootstrap.call(root:, step: dependency_step(manager: "npm", lockfile: "package-lock.json"))
      end

      assert_match(/missing package.json/, error.message)
      assert_empty runner.calls
    end
  end

  private

  def with_subject(lockfile:)
    Dir.mktmpdir("rundiff-js-bootstrap-") do |directory|
      root = Pathname(directory)
      root.join("package.json").write("{}\n")
      root.join(lockfile).write("lock\n")
      yield root
    end
  end

  def dependency_step(manager:, lockfile:, yarn_generation: nil)
    RunDiff::Subject::SetupPlan::Step.new(
      phase: "bootstrap",
      operation: "javascript.dependencies",
      provenance: "detected",
      details: {
        manager:,
        manifest: "package.json",
        lockfile:,
        frozen_lockfile: true,
        yarn_generation:
      }.compact
    )
  end
end
