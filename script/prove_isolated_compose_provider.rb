#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "socket"
require "tmpdir"
require_relative "../lib/rundiff/subject/execution_identity"
require_relative "../lib/rundiff/subject/isolated_compose_provider_client"
require_relative "../lib/rundiff/subject/runtime_capabilities"
require_relative "../lib/rundiff/subject/service_executor"
require_relative "../lib/rundiff/subject/setup_plan"

socket_path = ENV.fetch("RUNDIFF_COMPOSE_PROVIDER_SOCKET")
raise "executor must not receive Docker socket" if File.socket?("/var/run/docker.sock")

client = RunDiff::Subject::IsolatedComposeProviderClient.new(socket_path:).handshake!
raise "unexpected provider version" unless client.provider_version == "1"

base_capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
raise "production image must not statically declare Compose" if base_capabilities.service_provider?("compose")

capabilities = base_capabilities.with_service_provider("compose", client.provider_version)
raise "Compose capability handshake was not admitted" unless capabilities.service_provider?("compose")

Dir.mktmpdir("rundiff-isolated-compose-proof-") do |directory|
  root = Pathname(directory)
  root.join("compose.yml").write(<<~YAML)
    services:
      redis:
        image: redis:7-alpine
  YAML

  plan = RunDiff::Subject::SetupPlan.new(
    framework: "proof",
    steps: [
      {
        phase: "start_services",
        operation: "compose.run",
        provenance: "explicit",
        details: {
          name: "cache",
          manifest: "compose.yml",
          service: "redis",
          target_port: 6379,
          url_scheme: "redis",
          url_env: "REDIS_URL"
        }
      },
      {
        phase: "healthcheck",
        operation: "tcp.wait_ready",
        provenance: "explicit",
        details: {
          name: "cache",
          url_env: "REDIS_URL",
          timeout_seconds: 10
        }
      },
      {
        phase: "stop_services",
        operation: "compose.stop",
        provenance: "explicit",
        details: { name: "cache" }
      }
    ],
    evidence: {
      "executor_runtime_capabilities" => capabilities.to_h
    }
  )

  executor = RunDiff::Subject::ServiceExecutor.new(
    compose_provider: client,
    execution_identity: RunDiff::Subject::ExecutionIdentity.from_env
  )
  result = executor.start(
    root:,
    execution: Object.new,
    role: "candidate",
    env: {},
    setup_plan: plan
  )

  begin
    executor.healthcheck(
      root:,
      execution: Object.new,
      role: "candidate",
      env: result.env,
      setup_plan: plan,
      session: result.session
    )

    service = result.session.services.fetch(0)
    redis = TCPSocket.new(service.host, service.port)
    redis.write("*1\r\n$4\r\nPING\r\n")
    response = redis.gets
    raise "Redis did not answer PONG: #{response.inspect}" unless response == "+PONG\r\n"
    redis.close

    puts "provider_version=#{client.provider_version}"
    puts "compose_capability=#{capabilities.service_provider_version("compose")}"
    puts "published_host=#{service.host}"
    puts "redis_ping=PONG"
  ensure
    executor.stop(
      root:,
      execution: Object.new,
      role: "candidate",
      env: result.env,
      setup_plan: plan,
      session: result.session
    )
  end

  service = result.session.services.fetch(0)
  begin
    TCPSocket.new(service.host, service.port).close
    raise "Compose endpoint remained reachable after teardown"
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
    puts "endpoint_cleanup=true"
  end
end
