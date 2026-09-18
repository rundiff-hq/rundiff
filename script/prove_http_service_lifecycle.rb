#!/usr/bin/env ruby

require "active_support/core_ext/object/blank"
require "fileutils"
require "net/http"
require "pathname"
require "tmpdir"
require "uri"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze

require TOOL_ROOT.join("lib", "rundiff", "subject", "environment").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "configuration").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "javascript_package_manager_detector").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "rails_setup_plan_detector").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan_compiler").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "service_executor").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "lifecycle").to_s

module HttpServiceLifecycleProof
  class ProofEnvironment < RunDiff::Subject::Environment
    attr_reader :cleanup_count, :state_dir

    def initialize
      @cleanup_count = 0
    end

    def prepare(root:, execution:, role:)
      @state_dir = Pathname(Dir.mktmpdir("rundiff-subject-state-#{role}-"))
      { "RUNDIFF_SUBJECT_STATE_DIR" => @state_dir.to_s }
    end

    def env_for(root:, execution:, role:)
      {}
    end

    def cleanup(root:, execution:, role:)
      @cleanup_count += 1
      FileUtils.rm_rf(@state_dir) if @state_dir
    end
  end

  class RecordingServiceExecutor < RunDiff::Subject::ServiceExecutor
    attr_reader :last_pid, :last_state_dir, :last_url

    def start(**arguments)
      result = super
      if result.session
        service = result.session.services.fetch(0)
        @last_pid = service.pid
        @last_state_dir = result.session.state_dir
        @last_url = service.url
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
    success = prove_success_path
    failure = prove_readiness_failure_path

    puts "Configured HTTP subject service lifecycle proof"
    puts "configuration_contract=rundiff_yml"
    puts "setup_plan_start_operation=#{success.fetch(:start_operation)}"
    puts "setup_plan_healthcheck_operation=#{success.fetch(:healthcheck_operation)}"
    puts "setup_plan_stop_operation=#{success.fetch(:stop_operation)}"
    puts "service_runtime=#{success.fetch(:runtime)}"
    puts "service_entrypoint=#{success.fetch(:entrypoint)}"
    puts "service_provenance=explicit"
    puts "dynamic_port_assigned=#{URI(success.fetch(:url)).port.positive?}"
    puts "readiness_before_capture=true"
    puts "capture_service_response=#{success.fetch(:body)}"
    puts "success_service_stopped=#{!success.fetch(:service_executor).process_alive?}"
    puts "success_service_state_cleaned=#{!success.fetch(:service_state_dir).exist?}"
    puts "success_subject_state_cleaned=#{!success.fetch(:subject_state_dir).exist?}"
    puts "readiness_failure_capture_skipped=#{!failure.fetch(:capture_ran)}"
    puts "readiness_failure_service_stopped=#{!failure.fetch(:service_executor).process_alive?}"
    puts "readiness_failure_service_state_cleaned=#{!failure.fetch(:service_state_dir).exist?}"
    puts "readiness_failure_subject_state_cleaned=#{!failure.fetch(:subject_state_dir).exist?}"
    puts "teardown_order=service_stop_then_subject_cleanup"
  end

  def prove_success_path
    Dir.mktmpdir("rundiff-configured-service-success-") do |directory|
      root = Pathname(directory)
      write_subject(root, status: 200, timeout_seconds: 2)
      configuration = RunDiff::Subject::Configuration.load(root:)
      environment = ProofEnvironment.new
      service_executor = RecordingServiceExecutor.new
      lifecycle = lifecycle_for(environment:, service_executor:)
      capture_ran = false
      body = nil
      url = nil
      subject_state_dir = nil
      start_operation = healthcheck_operation = stop_operation = nil
      runtime = entrypoint = nil

      lifecycle.open(
        root:,
        execution: Object.new,
        role: "baseline",
        configuration:,
        setup_configuration: configuration
      ) do |session|
        capture_ran = true
        url = session.env.fetch("MOCK_API_URL")
        subject_state_dir = Pathname(session.env.fetch("RUNDIFF_SUBJECT_STATE_DIR"))
        raise "Subject state must exist during capture" unless subject_state_dir.directory?
        raise "Service state must exist during capture" unless service_executor.last_state_dir.directory?

        start_step = session.setup_plan.steps_for("start_services").fetch(0)
        start_operation = start_step.operation
        runtime = start_step.details.fetch("runtime")
        entrypoint = start_step.details.fetch("entrypoint")
        healthcheck_operation = session.setup_plan.steps_for("healthcheck").fetch(0).operation
        stop_operation = session.setup_plan.steps_for("stop_services").fetch(0).operation
        raise "Expected typed Ruby service runtime" unless runtime == "ruby"
        raise "Expected repository-relative service entrypoint" unless entrypoint == "service.rb"

        response = Net::HTTP.get_response(URI("#{url}/health"))
        raise "Expected healthy configured service during capture" unless response.code == "200"

        body = response.body
        raise "Unexpected configured service response #{body.inspect}" unless body == "OK"
      end

      raise "Lifecycle capture did not run after configured service readiness" unless capture_ran
      raise "Configured service remained alive after successful capture" if service_executor.process_alive?
      raise "Expected one subject cleanup after successful capture" unless environment.cleanup_count == 1
      raise "Configured service state survived teardown" if service_executor.last_state_dir.exist?
      raise "Subject state survived cleanup" if subject_state_dir.exist?

      return {
        service_executor:,
        service_state_dir: service_executor.last_state_dir,
        subject_state_dir:,
        body:,
        url:,
        start_operation:,
        healthcheck_operation:,
        stop_operation:,
        runtime:,
        entrypoint:
      }
    end
  end

  def prove_readiness_failure_path
    Dir.mktmpdir("rundiff-configured-service-failure-") do |directory|
      root = Pathname(directory)
      write_subject(root, status: 503, timeout_seconds: 1)
      configuration = RunDiff::Subject::Configuration.load(root:)
      environment = ProofEnvironment.new
      service_executor = RecordingServiceExecutor.new
      lifecycle = lifecycle_for(environment:, service_executor:)
      capture_ran = false
      error = nil

      begin
        lifecycle.open(
          root:,
          execution: Object.new,
          role: "candidate",
          configuration:,
          setup_configuration: configuration
        ) do
          capture_ran = true
        end
      rescue RunDiff::Subject::ServiceExecutor::Error => exception
        error = exception
      end

      raise "Expected configured service readiness failure" unless error
      raise "Expected readiness failure to report HTTP 503" unless error.message.include?("status=503")
      raise "Capture ran despite configured service readiness failure" if capture_ran
      raise "Configured service remained alive after readiness failure" if service_executor.process_alive?
      raise "Expected one subject cleanup after readiness failure" unless environment.cleanup_count == 1
      raise "Configured service state survived readiness-failure teardown" if service_executor.last_state_dir.exist?
      raise "Subject state survived readiness-failure cleanup" if environment.state_dir.exist?

      return {
        service_executor:,
        service_state_dir: service_executor.last_state_dir,
        subject_state_dir: environment.state_dir,
        capture_ran:
      }
    end
  end

  def lifecycle_for(environment:, service_executor:)
    RunDiff::Subject::Lifecycle.new(
      discovery: nil,
      environment:,
      setup_plan_compiler: RunDiff::Subject::SetupPlanCompiler.new,
      service_executor:
    )
  end

  def write_subject(root, status:, timeout_seconds:)
    FileUtils.mkdir_p(root.join("bin"))
    FileUtils.ln_s(TOOL_ROOT.join("Gemfile"), root.join("Gemfile"))
    FileUtils.ln_s(TOOL_ROOT.join("Gemfile.lock"), root.join("Gemfile.lock"))
    FileUtils.ln_s(TOOL_ROOT.join("bin", "rails"), root.join("bin", "rails"))

    root.join("service.rb").write(<<~RUBY)
      require "socket"

      status = Integer(ARGV.fetch(0), 10)
      server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("MOCK_API_PORT"), 10))
      trap("TERM") do
        server.close rescue nil
        exit! 0
      end

      loop do
        client = server.accept
        begin
          while (line = client.gets)
            break if line == "\\r\\n"
          end

          body = status == 200 ? "OK" : "NOT READY"
          reason = status == 200 ? "OK" : "Service Unavailable"
          client.write(
            "HTTP/1.1 " + status.to_s + " " + reason + "\\r\\n" +
            "Content-Type: text/plain\\r\\n" +
            "Content-Length: " + body.bytesize.to_s + "\\r\\n" +
            "Connection: close\\r\\n\\r\\n" +
            body
          )
        ensure
          client.close rescue nil
        end
      end
    RUBY

    root.join("rundiff.yml").write(<<~YAML)
      version: 1
      subject:
        services:
          - name: mock-api
            type: process
            runtime: ruby
            entrypoint: service.rb
            args: ["#{status}"]
            port_env: MOCK_API_PORT
            url_env: MOCK_API_URL
            readiness:
              type: http
              path: /health
              timeout_seconds: #{timeout_seconds}
    YAML
  end
end

HttpServiceLifecycleProof.call
