require "test_helper"

class RunDiffSubjectRailsPostgresEnvironmentTest < ActiveSupport::TestCase
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
    environment = RunDiff::Subject::RailsPostgresEnvironment.new(
      command_runner: CommandRecorder.new,
      postgres_url: "postgres://db.example"
    )

    assert_equal [ "rails" ], environment.capabilities_for(:framework)
    assert_equal [ "postgresql" ], environment.capabilities_for(:persistence)
    assert_equal [ "solid_queue" ], environment.capabilities_for(:queue)
    assert environment.capability?("telemetry.subject_owned_rails")
    assert environment.capability?("runtime.local_process")
    assert environment.capability?("state.isolated_comparable")
    assert environment.capability?("evidence.sql_queries")
  end

  test "prepares an isolated Rails PostgreSQL subject environment" do
    command_runner = CommandRecorder.new
    environment = RunDiff::Subject::RailsPostgresEnvironment.new(
      command_runner:,
      postgres_url: "postgres://db.example/"
    )
    execution = Execution.new("github-abcdef1234567890")
    root = Pathname("/tmp/customer-subject")

    env = environment.prepare(root:, execution:, role: "base")

    assert_equal "postgres://db.example/rundiff_app_abcdef123456_base", env.fetch("DATABASE_URL")
    assert_equal "postgres://db.example/rundiff_app_abcdef123456_base_queue", env.fetch("SOLID_QUEUE_DATABASE_URL")
    assert_equal root.join("Gemfile").to_s, env.fetch("BUNDLE_GEMFILE")
    assert_equal "test", env.fetch("RAILS_ENV")
    assert_equal "solid_queue", env.fetch("RUNDIFF_ASYNC_TRANSPORT")

    call = command_runner.calls.fetch(0)
    assert_equal env, call.fetch(:env)
    assert_equal [ root.join("bin", "rails").to_s, "db:prepare", "--trace" ], call.fetch(:command)
    assert_equal root.to_s, call.fetch(:chdir)
  end

  test "uses distinct subject state for baseline and candidate" do
    command_runner = CommandRecorder.new
    environment = RunDiff::Subject::RailsPostgresEnvironment.new(
      command_runner:,
      postgres_url: "postgres://db.example"
    )
    execution = Execution.new("github-abcdef1234567890")
    root = Pathname("/tmp/customer-subject")

    baseline = environment.env_for(root:, execution:, role: "base")
    candidate = environment.env_for(root:, execution:, role: "candidate")

    assert_not_equal baseline.fetch("DATABASE_URL"), candidate.fetch("DATABASE_URL")
    assert_not_equal baseline.fetch("SOLID_QUEUE_DATABASE_URL"), candidate.fetch("SOLID_QUEUE_DATABASE_URL")
    assert_match(/_base\z/, baseline.fetch("DATABASE_URL"))
    assert_match(/_candidate\z/, candidate.fetch("DATABASE_URL"))
  end
end
