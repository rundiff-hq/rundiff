require "test_helper"
require "tmpdir"

class RunDiffSubjectNodeProcessServiceTest < ActiveSupport::TestCase
  class Detector
    def call(root:, configuration:)
      RunDiff::Subject::SetupPlan.new(
        framework: "test",
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

  test "loads Node service and compiles it when executor declares Node" do
    Dir.mktmpdir("rundiff-node-service-") do |directory|
      root = Pathname(directory)
      write_configuration(root)
      configuration = RunDiff::Subject::Configuration.load(root:)
      service = configuration.services.fetch(0)

      assert_equal "node", service.runtime

      capabilities = RunDiff::Subject::RuntimeCapabilities.new(
        runtimes: { ruby: "3.4.10", node: "24.20.0" },
        package_managers: {}
      )
      compiler = RunDiff::Subject::SetupPlanCompiler.new(
        detectors: [ Detector.new ],
        runtime_capabilities: capabilities
      )
      plan = compiler.call(root:, configuration:)
      start = plan.steps_for("start_services").fetch(0)

      assert_equal "process.start", start.operation
      assert_equal "node", start.details.fetch("runtime")
      assert_equal "service.js", start.details.fetch("entrypoint")
      assert_equal capabilities.to_h, plan.evidence.fetch("executor_runtime_capabilities")
    end
  end

  test "fails closed before execution when Node is not a declared executor runtime" do
    Dir.mktmpdir("rundiff-node-service-") do |directory|
      root = Pathname(directory)
      write_configuration(root)
      configuration = RunDiff::Subject::Configuration.load(root:)
      compiler = RunDiff::Subject::SetupPlanCompiler.new(
        detectors: [ Detector.new ],
        runtime_capabilities: RunDiff::Subject::RuntimeCapabilities.ruby_only(version: "3.4.10")
      )

      error = assert_raises(RunDiff::Subject::SetupPlanCompiler::Error) do
        compiler.call(root:, configuration:)
      end

      assert_includes error.message, 'requires executor runtime "node"'
      assert_includes error.message, "declared runtimes: ruby"
    end
  end

  private

  def write_configuration(root)
    root.join("rundiff.yml").write(<<~YAML)
      version: 1
      subject:
        services:
          - name: node-api
            type: process
            runtime: node
            entrypoint: service.js
            args: ["ready"]
            port_env: NODE_API_PORT
            url_env: NODE_API_URL
            readiness:
              type: http
              path: /health
              timeout_seconds: 3
    YAML
  end
end
