require "test_helper"
require "tmpdir"

class RunDiffSubjectRailsBundleBootstrapTest < ActiveSupport::TestCase
  class RecordingRunner
    attr_reader :calls

    def initialize(fail_bundle_check: false)
      @fail_bundle_check = fail_bundle_check
      @calls = []
    end

    def call(env:, command:, chdir:)
      @calls << { env:, command:, chdir: }
      if @fail_bundle_check && command.last == "check"
        @fail_bundle_check = false
        raise RunDiff::Github::LocalPullRequestRunner::Error, "bundle check failed"
      end

      "true\n"
    end
  end

  test "requires a committed lockfile" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "Gemfile"), "source \"https://rubygems.org\"\n")
      bootstrap = RunDiff::Subject::RailsBundleBootstrap.new(
        command_runner: RecordingRunner.new,
        cache_root: File.join(directory, "cache")
      )

      error = assert_raises(RunDiff::Subject::RailsBundleBootstrap::Error) do
        bootstrap.call(root: directory)
      end

      assert_match(/must commit Gemfile.lock/, error.message)
    end
  end

  test "rejects a different Ruby major minor line" do
    Dir.mktmpdir do |directory|
      write_bundle_files(directory, ruby_version: "3.3.9")
      bootstrap = RunDiff::Subject::RailsBundleBootstrap.new(
        command_runner: RecordingRunner.new,
        cache_root: File.join(directory, "cache"),
        ruby_version: "3.4.10"
      )

      error = assert_raises(RunDiff::Subject::RailsBundleBootstrap::Error) do
        bootstrap.call(root: directory)
      end

      assert_match(/requires Ruby 3.3.9/, error.message)
      assert_match(/executor provides Ruby 3.4.10/, error.message)
    end
  end

  test "hydrates independent bundle caches from one trusted seed" do
    Dir.mktmpdir do |directory|
      baseline = Pathname(directory).join("baseline")
      candidate = Pathname(directory).join("candidate")
      seed_root = Pathname(directory).join("seed")
      FileUtils.mkdir_p([ baseline, candidate, seed_root ])
      write_bundle_files(baseline, ruby_version: "3.4.10")
      write_bundle_files(candidate, ruby_version: "3.4.10")

      cache_key = RunDiff::Subject::RailsBundleBootstrap.cache_key_for(
        lockfile: baseline.join("Gemfile.lock"),
        ruby_version: "3.4.10"
      )
      seed = seed_root.join(cache_key)
      FileUtils.mkdir_p(seed.join("gems"))
      seed.join("gems", "sentinel.txt").write("trusted-seed")

      runner = RecordingRunner.new
      bootstrap = RunDiff::Subject::RailsBundleBootstrap.new(
        command_runner: runner,
        cache_root: nil,
        ruby_version: "3.4.10",
        seed_root:
      )

      baseline_env = bootstrap.call(root: baseline)
      candidate_env = bootstrap.call(root: candidate)

      baseline_sentinel = Pathname(baseline_env.fetch("BUNDLE_PATH")).join("sentinel.txt")
      candidate_sentinel = Pathname(candidate_env.fetch("BUNDLE_PATH")).join("sentinel.txt")

      assert_equal "hit", baseline_env.fetch("RUNDIFF_SUBJECT_BUNDLE_SEED")
      assert_equal "hit", candidate_env.fetch("RUNDIFF_SUBJECT_BUNDLE_SEED")
      assert_equal "trusted-seed", baseline_sentinel.read
      assert_equal "trusted-seed", candidate_sentinel.read
      refute_equal baseline_env.fetch("BUNDLE_PATH"), candidate_env.fetch("BUNDLE_PATH")

      baseline_sentinel.write("baseline-mutated")

      assert_equal "baseline-mutated", baseline_sentinel.read
      assert_equal "trusted-seed", candidate_sentinel.read
      assert_equal "trusted-seed", seed.join("gems", "sentinel.txt").read
      refute runner.calls.any? { |call| call.fetch(:command).include?("install") }
    end
  end

  test "falls back to normal bundle install when no matching seed exists" do
    Dir.mktmpdir do |directory|
      write_bundle_files(directory, ruby_version: "3.4.10")
      runner = RecordingRunner.new(fail_bundle_check: true)
      bootstrap = RunDiff::Subject::RailsBundleBootstrap.new(
        command_runner: runner,
        cache_root: File.join(directory, "cache"),
        ruby_version: "3.4.10",
        seed_root: File.join(directory, "missing-seed")
      )

      env = bootstrap.call(root: directory)

      assert_equal "miss", env.fetch("RUNDIFF_SUBJECT_BUNDLE_SEED")
      assert runner.calls.any? { |call| call.fetch(:command).include?("install") }
    end
  end

  test "uses an executor-owned bundle cache and installs after a failed check" do
    Dir.mktmpdir do |directory|
      write_bundle_files(directory, ruby_version: "3.4.10")
      runner = RecordingRunner.new(fail_bundle_check: true)
      bootstrap = RunDiff::Subject::RailsBundleBootstrap.new(
        command_runner: runner,
        cache_root: File.join(directory, "cache"),
        ruby_version: "3.4.10"
      )

      env = bootstrap.call(root: directory)

      assert_equal File.join(directory, "Gemfile"), env.fetch("BUNDLE_GEMFILE")
      assert env.fetch("BUNDLE_PATH").start_with?(File.join(directory, "cache"))
      assert env.fetch("BUNDLE_APP_CONFIG").start_with?(File.join(directory, "cache"))
      assert_equal "true", env.fetch("BUNDLE_FROZEN")
      assert_equal "4.0.13", env.fetch("RUNDIFF_SUBJECT_BUNDLER_VERSION")
      assert runner.calls.any? { |call| call.fetch(:command).include?("install") }
    end
  end

  private

  def write_bundle_files(directory, ruby_version:)
    File.write(File.join(directory, "Gemfile"), "source \"https://rubygems.org\"\n")
    File.write(File.join(directory, ".ruby-version"), "#{ruby_version}\n")
    File.write(File.join(directory, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES

      RUBY VERSION
         ruby #{ruby_version}

      BUNDLED WITH
         4.0.13
    LOCK
  end
end
