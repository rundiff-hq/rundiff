require "test_helper"
require "tmpdir"

class RunDiffSubjectRailsSqliteEnvironmentTest < ActiveSupport::TestCase
  Execution = Data.define(:execution_id)

  class CommandRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(env:, command:, chdir:)
      @calls << { env:, command:, chdir: }
      ""
    end
  end

  test "declares the subject capabilities it actually provides" do
    environment = RunDiff::Subject::RailsSqliteEnvironment.new(command_runner: CommandRecorder.new)

    assert_equal [ "rails" ], environment.capabilities_for(:framework)
    assert_equal [ "sqlite" ], environment.capabilities_for(:persistence)
    assert_equal [ "active_job_test_adapter" ], environment.capabilities_for(:queue)
    assert environment.capability?("telemetry.subject_owned_rails")
    assert environment.capability?("runtime.local_process")
    assert environment.capability?("state.isolated_comparable")
    assert environment.capability?("evidence.sql_queries")
  end

  test "prepares an isolated Rails SQLite subject environment" do
    Dir.mktmpdir do |directory|
      command_runner = CommandRecorder.new
      bundle_path = File.join(directory, "bundle")
      bundle_app_config = File.join(directory, "bundle-config")
      environment = RunDiff::Subject::RailsSqliteEnvironment.new(
        command_runner:,
        state_root: directory,
        bundle_path:,
        bundle_app_config:
      )
      execution = Execution.new("github-abcdef1234567890")
      root = Pathname("/tmp/customer-subject")

      env = environment.prepare(root:, execution:, role: "base")

      assert_equal File.join(directory, "rundiff_subject_abcdef123456_base.sqlite3"), env.fetch("RUNDIFF_SQLITE_DATABASE")
      assert_equal root.join("Gemfile").to_s, env.fetch("BUNDLE_GEMFILE")
      assert_equal File.expand_path(bundle_path), env.fetch("BUNDLE_PATH")
      assert_equal File.expand_path(bundle_app_config), env.fetch("BUNDLE_APP_CONFIG")
      assert_nil env.fetch("DATABASE_URL")
      assert_nil env.fetch("SOLID_QUEUE_DATABASE_URL")
      assert_equal "test", env.fetch("RAILS_ENV")
      assert_equal "test_adapter", env.fetch("RUNDIFF_ASYNC_TRANSPORT")

      call = command_runner.calls.fetch(0)
      assert_equal env, call.fetch(:env)
      assert_equal [ RbConfig.ruby, root.join("bin", "rails").to_s, "db:prepare", "--trace" ], call.fetch(:command)
      assert_equal root.to_s, call.fetch(:chdir)
    end
  end

  test "uses distinct SQLite files for repeated samples of the same role" do
    Dir.mktmpdir do |directory|
      environment = RunDiff::Subject::RailsSqliteEnvironment.new(
        command_runner: CommandRecorder.new,
        state_root: directory
      )
      execution = Execution.new("github-abcdef1234567890")
      root = Pathname("/tmp/customer-subject")

      first = environment.env_for(root:, execution:, role: "base", sample_index: 1)
        .fetch("RUNDIFF_SQLITE_DATABASE")
      second = environment.env_for(root:, execution:, role: "base", sample_index: 2)
        .fetch("RUNDIFF_SQLITE_DATABASE")

      assert_match(/_base_s1\.sqlite3\z/, first)
      assert_match(/_base_s2\.sqlite3\z/, second)
      refute_equal first, second
    end
  end

  test "uses distinct SQLite files for baseline and candidate and cleans sidecars" do
    Dir.mktmpdir do |directory|
      environment = RunDiff::Subject::RailsSqliteEnvironment.new(
        command_runner: CommandRecorder.new,
        state_root: directory
      )
      execution = Execution.new("github-abcdef1234567890")
      root = Pathname("/tmp/customer-subject")

      baseline = environment.env_for(root:, execution:, role: "base").fetch("RUNDIFF_SQLITE_DATABASE")
      candidate = environment.env_for(root:, execution:, role: "candidate").fetch("RUNDIFF_SQLITE_DATABASE")

      assert_not_equal baseline, candidate
      assert_match(/_base\.sqlite3\z/, baseline)
      assert_match(/_candidate\.sqlite3\z/, candidate)

      [ baseline, "#{baseline}-wal", "#{baseline}-shm" ].each { |path| File.write(path, "stale") }
      environment.cleanup(root:, execution:, role: "base")

      assert_not File.exist?(baseline)
      assert_not File.exist?("#{baseline}-wal")
      assert_not File.exist?("#{baseline}-shm")
    end
  end
end
