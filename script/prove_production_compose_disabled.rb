#!/usr/bin/env ruby

require "pathname"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze
require TOOL_ROOT.join("lib", "rundiff", "subject", "runtime_capabilities").to_s

capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
if capabilities.service_provider?("compose")
  raise "Production executor must not declare Compose until it has an isolated service-provider boundary"
end

docker_present = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
  File.executable?(File.join(directory, "docker"))
end
raise "Production executor image must not expose Docker CLI to customer-code processes" if docker_present

puts "Production Compose isolation proof"
puts "compose_service_provider_declared=false"
puts "docker_cli_present=false"
puts "docker_socket_required=false"
