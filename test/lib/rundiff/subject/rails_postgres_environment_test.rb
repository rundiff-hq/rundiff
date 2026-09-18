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

  class RecordingAdminConnection
    attr_reader :url, :exec_params_calls, :exec_calls
    attr_accessor :closed

    def initialize(url)
      @url = url
      @exec_params_calls = []
      @exec_calls = []
      @closed = false
    end

    def exec_params(sql, params)
      @exec_params_calls << [ sql, params ]
    end

    def exec(sql)
      @exec_calls << sql
    end

    def close
      self.closed = true
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

  test "uses distinct PostgreSQL app and queue state for repeated samples" do
    environment = RunDiff::Subject::RailsPostgresEnvironment.new(
      command_runner: CommandRecorder.new,
      postgres_url: "postgres://db.example"
    )
    execution = Execution.new("github-abcdef1234567890")
    root = Pathname("/tmp/customer-subject")

    first = environment.env_for(root:, execution:, role: "candidate", sample_index: 1)
    second = environment.env_for(root:, execution:, role: "candidate", sample_index: 2)

    assert_match(/_candidate_s1\z/, first.fetch("DATABASE_URL"))
    assert_match(/_candidate_s2\z/, second.fetch("DATABASE_URL"))
    assert_match(/_candidate_queue_s1\z/, first.fetch("SOLID_QUEUE_DATABASE_URL"))
    assert_match(/_candidate_queue_s2\z/, second.fetch("SOLID_QUEUE_DATABASE_URL"))
    refute_equal first.fetch("DATABASE_URL"), second.fetch("DATABASE_URL")
    refute_equal first.fetch("SOLID_QUEUE_DATABASE_URL"), second.fetch("SOLID_QUEUE_DATABASE_URL")
  end

  test "drops sample-specific queue and app databases during cleanup" do
    connections = []
    factory = lambda do |url|
      RecordingAdminConnection.new(url).tap { |connection| connections << connection }
    end
    environment = RunDiff::Subject::RailsPostgresEnvironment.new(
      command_runner: CommandRecorder.new,
      postgres_url: "postgres://db.example",
      admin_connection_factory: factory
    )
    execution = Execution.new("github-abcdef1234567890")

    environment.cleanup(
      root: Pathname("/tmp/customer-subject"),
      execution:,
      role: "candidate",
      sample_index: 2
    )

    assert_equal 2, connections.length
    assert connections.all? { |connection| connection.url == "postgres://db.example/postgres" }
    assert connections.all?(&:closed)

    queue, app = connections
    assert_equal(
      [ "rundiff_app_abcdef123456_candidate_queue_s2" ],
      queue.exec_params_calls.fetch(0).fetch(1)
    )
    assert_equal(
      [ "rundiff_app_abcdef123456_candidate_s2" ],
      app.exec_params_calls.fetch(0).fetch(1)
    )
    assert_equal(
      'DROP DATABASE IF EXISTS "rundiff_app_abcdef123456_candidate_queue_s2"',
      queue.exec_calls.fetch(0)
    )
    assert_equal(
      'DROP DATABASE IF EXISTS "rundiff_app_abcdef123456_candidate_s2"',
      app.exec_calls.fetch(0)
    )
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
