require "test_helper"

class RunDiffSubjectLifecycleTest < ActiveSupport::TestCase
  Configuration = Data.define(:capture_env)

  class RecordingEnvironment < RunDiff::Subject::Environment
    attr_reader :events

    def initialize(events:, fail_on: nil)
      @events = events
      @fail_on = fail_on
    end

    def prepare(root:, execution:, role:)
      events << :prepare
      raise "prepare failed" if @fail_on == :prepare

      { "FROM_ENVIRONMENT" => "1" }
    end

    def start_services(root:, execution:, role:, env:)
      events << :start_services
      raise "start failed" if @fail_on == :start_services
    end

    def healthcheck(root:, execution:, role:, env:)
      events << :healthcheck
      raise "healthcheck failed" if @fail_on == :healthcheck
    end

    def stop_services(root:, execution:, role:, env:)
      events << :stop_services
    end

    def cleanup(root:, execution:, role:)
      events << :cleanup
    end
  end

  class RecordingDiscovery
    attr_reader :configuration

    def initialize(events:, environment:)
      @events = events
      @environment = environment
    end

    def resolve(root:, configuration:, runtime_env:)
      @configuration = configuration
      @events << [ :discover, runtime_env ]
      @environment
    end
  end

  class RecordingStageTimer
    attr_reader :stages

    def initialize
      @stages = []
    end

    def measure(execution_id:, stage:, role: nil)
      stages << [ execution_id, stage, role ]
      yield
    end
  end

  class FailingServiceExecutor
    def start(**)
      raise "Ruby service start must not run"
    end

    def healthcheck(**)
      raise "Ruby readiness must not run"
    end

    def stop(**)
      raise "Ruby service stop must not run"
    end
  end

  class RecordingSetupPlanCompiler
    attr_reader :configuration

    def initialize(events:, setup_plan:)
      @events = events
      @setup_plan = setup_plan
    end

    def call(root:, configuration:)
      @configuration = configuration
      @events << :compile_setup_plan
      @setup_plan
    end
  end

  test "orchestrates bootstrap, environment preparation, services, capture block, and teardown" do
    events = []
    environment = RecordingEnvironment.new(events:)
    lifecycle = lifecycle_for(events:, environment:)

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution: Object.new,
      role: "base",
      configuration: Configuration.new(capture_env: { "FROM_CAPTURE" => "1" })
    ) do |session|
      events << :capture
      assert_equal "1", session.env.fetch("FROM_ENVIRONMENT")
      assert_equal "1", session.env.fetch("FROM_CAPTURE")
    end

    assert_equal [
      [ :bootstrap, nil ],
      [ :discover, { "FROM_BOOTSTRAP" => "1" } ],
      :prepare,
      :start_services,
      :healthcheck,
      :capture,
      :stop_services,
      :cleanup
    ], events
  end

  test "compiles setup before bootstrap and keeps capture configuration separate" do
    events = []
    environment = RecordingEnvironment.new(events:)
    discovery = RecordingDiscovery.new(events:, environment:)
    setup_plan = RunDiff::Subject::SetupPlan.new(
      framework: "rails",
      steps: [
        {
          phase: "cleanup",
          operation: "subject.state_cleanup",
          provenance: "executor_default"
        }
      ]
    )
    compiler = RecordingSetupPlanCompiler.new(events:, setup_plan:)
    bootstrap = lambda do |root:, setup_plan:|
      events << [ :bootstrap, setup_plan ]
      { "FROM_BOOTSTRAP" => "1" }
    end
    lifecycle = RunDiff::Subject::Lifecycle.new(
      discovery:,
      bootstrap:,
      setup_plan_compiler: compiler
    )
    capture_configuration = Configuration.new(capture_env: { "FROM_CAPTURE" => "candidate" })
    setup_configuration = Object.new

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution: Object.new,
      role: "base",
      configuration: capture_configuration,
      setup_configuration:
    ) do |session|
      events << :capture
      assert_same setup_plan, session.setup_plan
      assert_equal "candidate", session.env.fetch("FROM_CAPTURE")
    end

    assert_same setup_configuration, compiler.configuration
    assert_same setup_configuration, discovery.configuration
    assert_equal [
      :compile_setup_plan,
      [ :bootstrap, setup_plan ],
      [ :discover, { "FROM_BOOTSTRAP" => "1" } ],
      :prepare,
      :start_services,
      :healthcheck,
      :capture,
      :stop_services,
      :cleanup
    ], events
  end

  test "uses prebootstrapped runtime environment without invoking bootstrap" do
    events = []
    environment = RecordingEnvironment.new(events:)
    bootstrap = lambda do |root:, setup_plan:|
      flunk "Ruby bootstrap must not run for Go-prepared runtime environment"
    end
    lifecycle = RunDiff::Subject::Lifecycle.new(
      discovery: RecordingDiscovery.new(events:, environment:),
      bootstrap:
    )

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution: Object.new,
      role: "base",
      configuration: Configuration.new(capture_env: {}),
      runtime_env: { "BUNDLE_PATH" => "/tmp/prepared-bundle" }
    ) do
      events << :capture
    end

    assert_includes events, [ :discover, { "BUNDLE_PATH" => "/tmp/prepared-bundle" } ]
    refute events.any? { |event| event.is_a?(Array) && event.first == :bootstrap }
  end

  test "uses Go-prepared subject environment without invoking environment prepare" do
    events = []
    environment = RecordingEnvironment.new(events:)
    lifecycle = RunDiff::Subject::Lifecycle.new(
      discovery: RecordingDiscovery.new(events:, environment:)
    )

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution: Object.new,
      role: "candidate",
      configuration: Configuration.new(capture_env: { "FROM_CAPTURE" => "1" }),
      runtime_env: { "BUNDLE_PATH" => "/tmp/bundle" },
      prepared_env: {
        "DATABASE_URL" => "postgres://prepared/candidate",
        "FROM_PREPARED" => "1"
      }
    ) do |session|
      events << :capture
      assert_equal "postgres://prepared/candidate", session.env.fetch("DATABASE_URL")
      assert_equal "1", session.env.fetch("FROM_PREPARED")
      assert_equal "1", session.env.fetch("FROM_CAPTURE")
    end

    refute_includes events, :prepare
    assert_includes events, :capture
    assert_includes events, :cleanup
  end

  test "uses Go-prepared services without invoking Ruby service executor" do
    events = []
    environment = RecordingEnvironment.new(events:)
    stage_timer = RecordingStageTimer.new
    lifecycle = RunDiff::Subject::Lifecycle.new(
      discovery: RecordingDiscovery.new(events:, environment:),
      service_executor: FailingServiceExecutor.new,
      stage_timer:
    )
    execution = Struct.new(:execution_id).new("github-services-test")

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution:,
      role: "base",
      configuration: Configuration.new(capture_env: {}),
      runtime_env: {},
      prepared_env: { "MOCK_API_URL" => "http://127.0.0.1:1234" },
      services_prepared: true
    ) do |session|
      events << :capture
      assert_equal "http://127.0.0.1:1234", session.env.fetch("MOCK_API_URL")
    end

    refute stage_timer.stages.any? { |(_, stage, _)| stage == "services_start" }
    assert_includes events, :capture
  end

  test "emits deterministic stage timings for one subject role" do
    events = []
    environment = RecordingEnvironment.new(events:)
    stage_timer = RecordingStageTimer.new
    lifecycle = RunDiff::Subject::Lifecycle.new(
      discovery: RecordingDiscovery.new(events:, environment:),
      bootstrap: lambda { |root:, setup_plan:| { "FROM_BOOTSTRAP" => "1" } },
      stage_timer:
    )
    execution = Struct.new(:execution_id).new("github-stage-test")

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution:,
      role: "candidate",
      configuration: Configuration.new(capture_env: {})
    ) do
      events << :capture
    end

    assert_equal(
      [
        [ "github-stage-test", "setup_plan", "candidate" ],
        [ "github-stage-test", "bootstrap", "candidate" ],
        [ "github-stage-test", "environment_resolve", "candidate" ],
        [ "github-stage-test", "environment_prepare", "candidate" ],
        [ "github-stage-test", "services_start", "candidate" ],
        [ "github-stage-test", "capture", "candidate" ],
        [ "github-stage-test", "cleanup", "candidate" ]
      ],
      stage_timer.stages
    )
  end

  test "stops services and cleans up when readiness fails" do
    events = []
    environment = RecordingEnvironment.new(events:, fail_on: :healthcheck)
    lifecycle = lifecycle_for(events:, environment:)

    error = assert_raises(RuntimeError) do
      lifecycle.open(
        root: Pathname("/tmp/subject"),
        execution: Object.new,
        role: "candidate",
        configuration: Configuration.new(capture_env: {})
      ) { flunk "capture must not run" }
    end

    assert_equal "healthcheck failed", error.message
    assert_equal [
      [ :bootstrap, nil ],
      [ :discover, { "FROM_BOOTSTRAP" => "1" } ],
      :prepare,
      :start_services,
      :healthcheck,
      :stop_services,
      :cleanup
    ], events
  end

  test "cleans up without stopping services when preparation fails" do
    events = []
    environment = RecordingEnvironment.new(events:, fail_on: :prepare)
    lifecycle = lifecycle_for(events:, environment:)

    assert_raises(RuntimeError) do
      lifecycle.open(
        root: Pathname("/tmp/subject"),
        execution: Object.new,
        role: "base",
        configuration: Configuration.new(capture_env: {})
      ) { flunk "capture must not run" }
    end

    assert_equal [
      [ :bootstrap, nil ],
      [ :discover, { "FROM_BOOTSTRAP" => "1" } ],
      :prepare,
      :cleanup
    ], events
  end

  private

  def lifecycle_for(events:, environment:)
    bootstrap = lambda do |root:, setup_plan:|
      events << [ :bootstrap, setup_plan ]
      { "FROM_BOOTSTRAP" => "1" }
    end
    discovery = RecordingDiscovery.new(events:, environment:)

    RunDiff::Subject::Lifecycle.new(discovery:, bootstrap:)
  end
end
