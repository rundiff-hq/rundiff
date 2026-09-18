#!/usr/bin/env ruby

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "net/http"

module RemoteExecutorTimeoutDiagnosticsProof
  module_function

  def call
    prove_timeout(
      error: Net::ReadTimeout.new("timed out"),
      expected_phase: "remote_executor_wait"
    )
    prove_timeout(
      error: Net::OpenTimeout.new("timed out"),
      expected_phase: "remote_executor_connect"
    )

    puts "executor_timeout_diagnostics_proof=passed"
    puts "execution_id=github-timeout-proof"
    puts "read_timeout_phase=remote_executor_wait"
    puts "open_timeout_phase=remote_executor_connect"
    puts "secret_leak=false"
  end

  def prove_timeout(error:, expected_phase:)
    transport = Struct.new(:error) do
      def call(**)
        raise error
      end
    end.new(error)

    adapter = RunDiff::Executor::HttpAdapter.new(
      url: "https://executor.example.test/v1/executions",
      token: "remote-secret",
      open_timeout: 3,
      read_timeout: 120,
      transport:
    )

    raised = begin
      adapter.call(request: request)
      nil
    rescue RunDiff::Executor::HttpAdapter::Error => exception
      exception
    end

    raise "Expected remote executor timeout error" unless raised

    message = raised.message
    expected_class = error.class.name

    raise "Missing execution id in timeout error: #{message}" unless message.include?('execution_id="github-timeout-proof"')
    raise "Missing timeout phase #{expected_phase}: #{message}" unless message.include?("phase=#{expected_phase}")
    raise "Missing timeout class #{expected_class}: #{message}" unless message.include?("error_class=#{expected_class}")
    raise "Remote executor token leaked into timeout error" if message.include?("remote-secret")

    puts "timeout_phase=#{expected_phase} error_class=#{expected_class} verified=true"
  end

  def request
    @request ||= RunDiff::Executor::Request.new(
      schema_version: "1",
      execution_id: "github-timeout-proof",
      scenario_id: "timeout-diagnostics",
      baseline_sha: "base",
      candidate_sha: "head",
      attempt_number: 1,
      context: {
        "repository" => "rundiff-hq/rundiff",
        "candidate_repository" => "rundiff-hq/rundiff",
        "pull_request_number" => 1,
        "baseline_ref" => "main",
        "candidate_ref" => "candidate"
      }
    )
  end
end

RemoteExecutorTimeoutDiagnosticsProof.call
