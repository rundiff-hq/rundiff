#!/usr/bin/env ruby

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "json"
require "rbconfig"

module RemoteExecutorTopologyProof
  class StaticRepositoryCapabilityProvider
    def initialize(token:)
      @capability = RunDiff::Executor::RepositoryCapability.new(token:)
    end

    def call(request:)
      @capability
    end
  end

  module_function

  def call
    prove_customer_subprocess_environment_isolated!

    request = RunDiff::Executor::Request.new(
      schema_version: RunDiff::Executor::Request.current_schema_version,
      execution_id: ENV.fetch("RUNDIFF_PROOF_EXECUTION_ID"),
      scenario_id: "production.remote-executor-topology",
      baseline_sha: ENV.fetch("RUNDIFF_PROOF_BASELINE_SHA"),
      candidate_sha: ENV.fetch("RUNDIFF_PROOF_CANDIDATE_SHA"),
      attempt_number: 1,
      context: {
        "repository" => ENV.fetch("RUNDIFF_PROOF_REPOSITORY"),
        "candidate_repository" => ENV.fetch("RUNDIFF_PROOF_REPOSITORY"),
        "pull_request_number" => Integer(ENV.fetch("RUNDIFF_PROOF_PULL_REQUEST_NUMBER")),
        "baseline_ref" => ENV.fetch("RUNDIFF_PROOF_BASELINE_REF"),
        "candidate_ref" => ENV.fetch("RUNDIFF_PROOF_CANDIDATE_REF")
      }
    )

    adapter = RunDiff::Executor::HttpAdapter.new(
      url: ENV.fetch("RUNDIFF_REMOTE_EXECUTOR_URL"),
      token: ENV.fetch("RUNDIFF_REMOTE_EXECUTOR_TOKEN"),
      repository_capability_provider: StaticRepositoryCapabilityProvider.new(
        token: ENV.fetch("RUNDIFF_PROOF_REPOSITORY_TOKEN")
      )
    )

    dispatch_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = adapter.call(request:)
    dispatch_elapsed_ms = (
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - dispatch_started_at) * 1_000
    ).round
    unless result.success?
      raise "Remote executor failed: #{result.error_class}: #{result.error_message}"
    end

    payload = result.payload
    unless payload.is_a?(Hash) && payload.dig("executions", "baseline") && payload.dig("executions", "candidate")
      raise "Remote executor returned a successful Result without baseline/candidate behavioral payload"
    end

    puts "Remote executor topology proof"
    puts "request_schema=#{request.schema_version}"
    puts "result_schema=#{result.schema_version}"
    puts "result_status=#{result.status}"
    puts "repository=#{request.context.fetch("repository")}"
    puts "baseline_sha=#{request.baseline_sha}"
    puts "candidate_sha=#{request.candidate_sha}"
    puts "repository_capability_transport=out_of_band_header"
    puts "customer_subprocess_env_isolated=true"
    puts "separate_executor_process=true"
    puts "remote_executor_topology_dispatch_elapsed_ms=#{dispatch_elapsed_ms}"
  end

  def prove_customer_subprocess_environment_isolated!
    secret_keys = %w[
      RUNDIFF_REMOTE_EXECUTOR_TOKEN
      RUNDIFF_PROOF_REPOSITORY_TOKEN
      RUBYOPT
      RUBYLIB
    ]
    script = "require 'json'; print JSON.generate(ENV.to_h.slice(*#{(secret_keys + [ "RUNDIFF_EXPLICIT_SENTINEL" ]).inspect}))"
    runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new
    output = runner.call(
      env: { "RUNDIFF_EXPLICIT_SENTINEL" => "visible" },
      command: [ RbConfig.ruby, "-e", script ],
      chdir: Rails.root.to_s
    )
    child_env = JSON.parse(output)

    leaked = secret_keys.select { |key| child_env.key?(key) }
    raise "Customer subprocess inherited sensitive host environment: #{leaked.join(", ")}" if leaked.any?
    raise "Explicit subprocess environment was lost" unless child_env["RUNDIFF_EXPLICIT_SENTINEL"] == "visible"
  end
end

RemoteExecutorTopologyProof.call
