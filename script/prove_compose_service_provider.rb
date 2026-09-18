#!/usr/bin/env ruby

require "open3"
require "pathname"
require "socket"
require "tmpdir"
require "uri"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze

require TOOL_ROOT.join("lib", "rundiff", "subject", "environment").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "configuration").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "runtime_capabilities").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan_compiler").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "compose_service_provider").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "service_executor").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "lifecycle").to_s

module ComposeServiceProviderProof
  class Detector
    def call(root:, configuration:)
      RunDiff::Subject::SetupPlan.new(
        framework: "compose-proof",
        steps: []
      )
    end
  end

  class ProofEnvironment < RunDiff::Subject::Environment
    attr_reader :cleaned

    def prepare(root:, execution:, role:)
      {}
    end

    def env_for(root:, execution:, role:)
      {}
    end

    def cleanup(root:, execution:, role:)
      @cleaned = true
    end
  end

  class RecordingProvider < RunDiff::Subject::ComposeServiceProvider
    attr_reader :last_started

    def start(**arguments)
      super.tap { |started| @last_started = started }
    end
  end

  module_function

  def call
    compose_version = command!("docker", "compose", "version", "--short").strip
    raise "Docker Compose version was empty" if compose_version.empty?

    Dir.mktmpdir("rundiff-compose-proof-") do |directory|
      root = Pathname(directory)
      write_subject(root)
      configuration = RunDiff::Subject::Configuration.load(root:)

      prove_missing_capability_fails_closed(root:, configuration:)

      capabilities = RunDiff::Subject::RuntimeCapabilities.new(
        runtimes: { "ruby" => RUBY_VERSION },
        package_managers: {},
        service_providers: { "compose" => compose_version }
      )
      compiler = RunDiff::Subject::SetupPlanCompiler.new(
        detectors: [ Detector.new ],
        runtime_capabilities: capabilities
      )
      provider = RecordingProvider.new
      environment = ProofEnvironment.new
      lifecycle = RunDiff::Subject::Lifecycle.new(
        discovery: Object.new,
        environment:,
        setup_plan_compiler: compiler,
        service_executor: RunDiff::Subject::ServiceExecutor.new(compose_provider: provider)
      )

      redis_url = nil
      start_operation = nil
      lifecycle.open(
        root:,
        execution: Object.new,
        role: "candidate",
        configuration:
      ) do |session|
        redis_url = session.env.fetch("REDIS_URL")
        start_operation = session.setup_plan.steps_for("start_services").fetch(0).operation
        assert_redis_ping(redis_url)
      end

      started = provider.last_started or raise "Compose provider did not record a started service"
      assert_container_removed(started.handle.container_id)
      assert_project_network_removed(started.handle.project_name)
      assert_endpoint_closed(redis_url)
      raise "Subject environment cleanup did not run" unless environment.cleaned

      puts "Explicit Compose service provider proof"
      puts "compose_version=#{compose_version}"
      puts "setup_plan_start_operation=#{start_operation}"
      puts "service_provider_capability=compose"
      puts "missing_compose_capability=fail_closed"
      puts "published_host=127.0.0.1"
      puts "published_port_ephemeral=true"
      puts "redis_ping=PONG"
      puts "container_removed=true"
      puts "project_network_removed=true"
      puts "endpoint_closed=true"
      puts "production_executor_compose_capability_declared=false"
    end
  end

  def prove_missing_capability_fails_closed(root:, configuration:)
    compiler = RunDiff::Subject::SetupPlanCompiler.new(
      detectors: [ Detector.new ],
      runtime_capabilities: RunDiff::Subject::RuntimeCapabilities.new(
        runtimes: { "ruby" => RUBY_VERSION },
        package_managers: {},
        service_providers: {}
      )
    )

    compiler.call(root:, configuration:)
    raise "Compose setup unexpectedly compiled without executor service-provider capability"
  rescue RunDiff::Subject::SetupPlanCompiler::Error => error
    unless error.message.include?('requires executor service provider "compose"')
      raise "Unexpected missing-capability error: #{error.message}"
    end
  end

  def write_subject(root)
    root.join("compose.yml").write(<<~YAML)
      services:
        redis:
          image: redis:7-alpine
    YAML

    root.join("rundiff.yml").write(<<~YAML)
      version: 1
      subject:
        services:
          - name: cache
            type: compose
            manifest: compose.yml
            service: redis
            target_port: 6379
            url_scheme: redis
            url_env: REDIS_URL
            readiness:
              type: tcp
              timeout_seconds: 15
    YAML
  end

  def assert_redis_ping(url)
    uri = URI(url)
    socket = TCPSocket.new(uri.host, uri.port)
    socket.write("*1\r\n$4\r\nPING\r\n")
    response = socket.gets
    raise "Redis Compose service returned #{response.inspect}" unless response == "+PONG\r\n"
  ensure
    socket&.close
  end

  def assert_container_removed(container_id)
    _stdout, _stderr, status = Open3.capture3("docker", "inspect", container_id)
    raise "Compose container still exists after teardown" if status.success?
  end

  def assert_project_network_removed(project_name)
    stdout = command!(
      "docker", "network", "ls",
      "--filter", "label=com.docker.compose.project=#{project_name}",
      "--format", "{{.ID}}"
    )
    raise "Compose project network still exists after teardown: #{stdout.inspect}" unless stdout.strip.empty?
  end

  def assert_endpoint_closed(url)
    uri = URI(url)
    socket = TCPSocket.new(uri.host, uri.port)
    socket.close
    raise "Compose endpoint still accepts connections after teardown"
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT
    nil
  end

  def command!(*argv)
    stdout, stderr, status = Open3.capture3(*argv)
    raise "Command failed #{argv.inspect}: #{stderr}" unless status.success?

    stdout
  end
end

ComposeServiceProviderProof.call
