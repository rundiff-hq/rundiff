#!/usr/bin/env ruby

require "active_support/core_ext/object/blank"
require "fileutils"
require "net/http"
require "open3"
require "pathname"
require "tmpdir"
require "uri"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze

require TOOL_ROOT.join("lib", "rundiff", "subject", "environment").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "configuration").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "runtime_capabilities").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "javascript_package_manager_detector").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "rails_setup_plan_detector").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan_compiler").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "service_executor").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "lifecycle").to_s

module NodeServiceRuntimeProof
  class ProofEnvironment < RunDiff::Subject::Environment
    attr_reader :state_dir

    def prepare(root:, execution:, role:)
      @state_dir = Pathname(Dir.mktmpdir("rundiff-node-subject-state-#{role}-"))
      { "RUNDIFF_SUBJECT_STATE_DIR" => @state_dir.to_s }
    end

    def env_for(root:, execution:, role:)
      {}
    end

    def cleanup(root:, execution:, role:)
      FileUtils.rm_rf(@state_dir) if @state_dir
    end
  end

  class RecordingServiceExecutor < RunDiff::Subject::ServiceExecutor
    attr_reader :last_pid, :last_state_dir

    def start(**arguments)
      result = super
      if result.session
        @last_pid = result.session.services.fetch(0).pid
        @last_state_dir = result.session.state_dir
      end
      result
    end

    def process_alive?
      return false unless @last_pid

      Process.kill(0, @last_pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end

  module_function

  def call
    capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
    declared_node = capabilities.runtime_version("node")
    raise "Production executor does not declare Node runtime" unless declared_node

    stdout, stderr, status = Open3.capture3("node", "--version")
    raise "Could not execute Node runtime: #{stderr}" unless status.success?

    actual_node = stdout.strip.delete_prefix("v")
    unless actual_node == declared_node
      raise "Declared Node #{declared_node.inspect} does not match actual runtime #{actual_node.inspect}"
    end

    prove_capability_rejection
    success = prove_node_service(capabilities:)

    puts "Node process service runtime proof"
    puts "declared_node_version=#{declared_node}"
    puts "actual_node_version=#{actual_node}"
    puts "configuration_runtime=node"
    puts "setup_plan_start_operation=#{success.fetch(:start_operation)}"
    puts "setup_plan_runtime=#{success.fetch(:runtime)}"
    puts "runtime_capability_gate=passed"
    puts "missing_node_capability=fail_closed"
    puts "dynamic_port_assigned=#{URI(success.fetch(:url)).port.positive?}"
    puts "readiness_before_capture=true"
    puts "capture_service_response=#{success.fetch(:body)}"
    puts "node_service_stopped=#{!success.fetch(:service_executor).process_alive?}"
    puts "service_state_cleaned=#{!success.fetch(:service_state_dir).exist?}"
    puts "subject_state_cleaned=#{!success.fetch(:subject_state_dir).exist?}"
  end

  def prove_capability_rejection
    Dir.mktmpdir("rundiff-node-capability-rejection-") do |directory|
      root = Pathname(directory)
      write_subject(root)
      configuration = RunDiff::Subject::Configuration.load(root:)
      compiler = RunDiff::Subject::SetupPlanCompiler.new(
        runtime_capabilities: RunDiff::Subject::RuntimeCapabilities.ruby_only
      )

      begin
        compiler.call(root:, configuration:)
      rescue RunDiff::Subject::SetupPlanCompiler::Error => error
        return if error.message.include?('requires executor runtime "node"')

        raise "Unexpected Node capability rejection: #{error.message}"
      end

      raise "Node service compiled without a declared Node runtime"
    end
  end

  def prove_node_service(capabilities:)
    Dir.mktmpdir("rundiff-node-service-proof-") do |directory|
      root = Pathname(directory)
      write_subject(root)
      configuration = RunDiff::Subject::Configuration.load(root:)
      environment = ProofEnvironment.new
      service_executor = RecordingServiceExecutor.new
      lifecycle = RunDiff::Subject::Lifecycle.new(
        discovery: nil,
        environment:,
        setup_plan_compiler: RunDiff::Subject::SetupPlanCompiler.new(runtime_capabilities: capabilities),
        service_executor:
      )
      url = body = subject_state_dir = nil
      start_operation = runtime = nil

      lifecycle.open(
        root:,
        execution: Object.new,
        role: "candidate",
        configuration:,
        setup_configuration: configuration
      ) do |session|
        start_step = session.setup_plan.steps_for("start_services").fetch(0)
        start_operation = start_step.operation
        runtime = start_step.details.fetch("runtime")
        raise "Expected Node service runtime" unless runtime == "node"

        url = session.env.fetch("NODE_API_URL")
        subject_state_dir = Pathname(session.env.fetch("RUNDIFF_SUBJECT_STATE_DIR"))
        raise "Subject state must exist during capture" unless subject_state_dir.directory?
        raise "Service state must exist during capture" unless service_executor.last_state_dir.directory?

        response = Net::HTTP.get_response(URI("#{url}/health"))
        raise "Expected healthy Node service during capture" unless response.code == "200"

        body = response.body
        raise "Unexpected Node service response #{body.inspect}" unless body == "NODE OK"
      end

      raise "Node service remained alive after capture" if service_executor.process_alive?
      raise "Node service state survived teardown" if service_executor.last_state_dir.exist?
      raise "Subject state survived cleanup" if subject_state_dir.exist?

      return {
        service_executor:,
        service_state_dir: service_executor.last_state_dir,
        subject_state_dir:,
        body:,
        url:,
        start_operation:,
        runtime:
      }
    end
  end

  def write_subject(root)
    FileUtils.mkdir_p(root.join("bin"))
    FileUtils.ln_s(TOOL_ROOT.join("Gemfile"), root.join("Gemfile"))
    FileUtils.ln_s(TOOL_ROOT.join("Gemfile.lock"), root.join("Gemfile.lock"))
    FileUtils.ln_s(TOOL_ROOT.join("bin", "rails"), root.join("bin", "rails"))

    root.join("service.js").write(<<~JAVASCRIPT)
      const http = require("http");

      const port = Number(process.env.NODE_API_PORT);
      const server = http.createServer((request, response) => {
        if (request.url === "/health") {
          response.writeHead(200, { "Content-Type": "text/plain" });
          response.end("NODE OK");
          return;
        }

        response.writeHead(404, { "Content-Type": "text/plain" });
        response.end("NOT FOUND");
      });

      process.on("SIGTERM", () => {
        server.close(() => process.exit(0));
      });

      server.listen(port, "127.0.0.1");
    JAVASCRIPT

    root.join("rundiff.yml").write(<<~YAML)
      version: 1
      subject:
        services:
          - name: node-api
            type: process
            runtime: node
            entrypoint: service.js
            port_env: NODE_API_PORT
            url_env: NODE_API_URL
            readiness:
              type: http
              path: /health
              timeout_seconds: 3
    YAML
  end
end

NodeServiceRuntimeProof.call
