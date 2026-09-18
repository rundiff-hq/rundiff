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

  class SampleAwareEnvironment < RecordingEnvironment
    attr_reader :sample_indexes

    def initialize(events:)
      super(events:)
      @sample_indexes = []
    end

    def prepare(root:, execution:, role:, sample_index:)
      sample_indexes << [ :prepare, sample_index ]
      super(root:, execution:, role:)
    end

    def cleanup(root:, execution:, role:, sample_index:)
      sample_indexes << [ :cleanup, sample_index ]
      super(root:, execution:, role:)
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

  test "passes sample index only to sample-aware state preparation and cleanup" do
    events = []
    environment = SampleAwareEnvironment.new(events:)
    lifecycle = lifecycle_for(events:, environment:)

    lifecycle.open(
      root: Pathname("/tmp/subject"),
      execution: Object.new,
      role: "base",
      sample_index: 2,
      configuration: Configuration.new(capture_env: {})
    ) do
      events << :capture
    end

    assert_equal [ [ :prepare, 2 ], [ :cleanup, 2 ] ], environment.sample_indexes
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
