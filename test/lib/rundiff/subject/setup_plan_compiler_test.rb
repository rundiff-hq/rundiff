require "test_helper"
require "tmpdir"

class RunDiffSubjectSetupPlanCompilerTest < ActiveSupport::TestCase
  Configuration = Data.define(:persistence, :services)

  class Detector
    def initialize(plan: nil)
      @plan = plan
    end

    def call(root:, configuration:)
      @plan
    end
  end

  test "returns the single detected setup plan" do
    plan = setup_plan("rails")
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new(plan:) ]
    )

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      assert_same plan, compiler.call(
        root: Pathname(directory),
        configuration: configuration
      )
    end
  end

  test "compiles explicit process services into typed lifecycle operations" do
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new(plan: setup_plan("rails")) ]
    )
    service = process_service

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      compiled = compiler.call(
        root: Pathname(directory),
        configuration: configuration(services: [ service ])
      )

      assert_equal [ "process.start" ], compiled.steps_for("start_services").map(&:operation)
      assert_equal [ "http.wait_ready" ], compiled.steps_for("healthcheck").map(&:operation)
      assert_equal [ "process.stop" ], compiled.steps_for("stop_services").map(&:operation)
      assert_equal [ "mock-api" ], compiled.evidence.fetch("explicit_services")

      start = compiled.steps_for("start_services").fetch(0)
      assert_equal "explicit", start.provenance
      assert_equal "ruby", start.details.fetch("runtime")
      assert_equal "script/mock_api.rb", start.details.fetch("entrypoint")
      assert_equal [ "ready" ], start.details.fetch("args")
      assert_equal "MOCK_API_PORT", start.details.fetch("port_env")
      assert_equal "MOCK_API_URL", start.details.fetch("url_env")

      readiness = compiled.steps_for("healthcheck").fetch(0)
      assert_equal "/health", readiness.details.fetch("path")
      assert_equal 4, readiness.details.fetch("timeout_seconds")
    end
  end

  test "compiles explicit Compose services only when executor declares the provider" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.new(
      runtimes: { ruby: "3.4.10" },
      package_managers: {},
      service_providers: { compose: "2.40.0" }
    )
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new(plan: setup_plan("rails")) ],
      runtime_capabilities: capabilities
    )

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      compiled = compiler.call(
        root: Pathname(directory),
        configuration: configuration(services: [ compose_service ])
      )

      assert_equal [ "compose.run" ], compiled.steps_for("start_services").map(&:operation)
      assert_equal [ "tcp.wait_ready" ], compiled.steps_for("healthcheck").map(&:operation)
      assert_equal [ "compose.stop" ], compiled.steps_for("stop_services").map(&:operation)

      start = compiled.steps_for("start_services").fetch(0)
      assert_equal "compose.yml", start.details.fetch("manifest")
      assert_equal "redis", start.details.fetch("service")
      assert_equal 6379, start.details.fetch("target_port")
      assert_equal "redis", start.details.fetch("url_scheme")
      assert_equal "REDIS_URL", start.details.fetch("url_env")
    end
  end

  test "fails closed when Compose provider capability is absent" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.new(
      runtimes: { ruby: "3.4.10" },
      package_managers: {},
      service_providers: {}
    )
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new(plan: setup_plan("rails")) ],
      runtime_capabilities: capabilities
    )

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      error = assert_raises(RunDiff::Subject::SetupPlanCompiler::Error) do
        compiler.call(
          root: Pathname(directory),
          configuration: configuration(services: [ compose_service ])
        )
      end

      assert_includes error.message, 'requires executor service provider "compose"'
      assert_includes error.message, "declared service providers: none"
    end
  end

  test "records declared executor runtime capabilities in plan evidence" do
    plan = RunDiff::Subject::SetupPlan.new(
      framework: "rails",
      steps: [],
      evidence: { "framework" => "rails" }
    )
    capabilities = RunDiff::Subject::RuntimeCapabilities.new(
      runtimes: { ruby: "3.4.10", node: "24.0.0" },
      package_managers: { pnpm: "10.0.0" },
      service_providers: { compose: "2.40.0" }
    )
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new(plan:) ],
      runtime_capabilities: capabilities
    )

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      compiled = compiler.call(
        root: Pathname(directory),
        configuration: configuration
      )

      assert_equal "rails", compiled.evidence.fetch("framework")
      assert_equal capabilities.to_h, compiled.evidence.fetch("executor_runtime_capabilities")
      refute_same plan, compiled
    end
  end

  test "fails closed when no detector can compile the subject" do
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new ]
    )

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      error = assert_raises(RunDiff::Subject::SetupPlanCompiler::Error) do
        compiler.call(
          root: Pathname(directory),
          configuration: configuration
        )
      end

      assert_includes error.message, "Could not compile a subject setup plan"
    end
  end

  test "fails closed when multiple detectors claim the subject" do
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new(plan: setup_plan("rails")), Detector.new(plan: setup_plan("other")) ]
    )

    Dir.mktmpdir("rundiff-plan-compiler-") do |directory|
      error = assert_raises(RunDiff::Subject::SetupPlanCompiler::Error) do
        compiler.call(
          root: Pathname(directory),
          configuration: configuration
        )
      end

      assert_includes error.message, "Ambiguous subject setup plan"
      assert_includes error.message, "other, rails"
    end
  end

  private

  def configuration(services: [])
    Configuration.new(persistence: "auto", services:)
  end

  def process_service
    RunDiff::Subject::Configuration::Service.new(
      name: "mock-api",
      type: "process",
      runtime: "ruby",
      entrypoint: "script/mock_api.rb",
      args: [ "ready" ].freeze,
      port_env: "MOCK_API_PORT",
      url_env: "MOCK_API_URL",
      readiness: RunDiff::Subject::Configuration::Readiness.new(
        type: "http",
        path: "/health",
        timeout_seconds: 4
      )
    )
  end

  def compose_service
    RunDiff::Subject::Configuration::ComposeService.new(
      name: "cache",
      type: "compose",
      manifest: "compose.yml",
      service: "redis",
      target_port: 6379,
      url_scheme: "redis",
      url_env: "REDIS_URL",
      readiness: RunDiff::Subject::Configuration::Readiness.new(
        type: "tcp",
        path: nil,
        timeout_seconds: 5
      )
    )
  end

  def setup_plan(framework)
    RunDiff::Subject::SetupPlan.new(
      framework:,
      steps: [
        {
          phase: "cleanup",
          operation: "subject.state_cleanup",
          provenance: "executor_default"
        }
      ]
    )
  end
end
