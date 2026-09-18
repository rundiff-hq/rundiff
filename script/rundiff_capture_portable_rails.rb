#!/usr/bin/env ruby

SUBJECT_ROOT = Dir.pwd.freeze

require File.join(SUBJECT_ROOT, "config/environment")
require "json"
require "net/http"
require "securerandom"

begin
  require "rack/mock_request"
rescue LoadError
  require "rack/mock"
end

module RunDiffPortableNetHttpInstrumentation
  THREAD_KEY = :rundiff_portable_http_requests

  def request(*arguments, &block)
    counter = Thread.current[THREAD_KEY]
    Thread.current[THREAD_KEY] = counter + 1 if counter
    super
  end
end

Net::HTTP.prepend(RunDiffPortableNetHttpInstrumentation) unless Net::HTTP < RunDiffPortableNetHttpInstrumentation

class RunDiffPortableRailsCapture
  IGNORED_SQL_NAMES = %w[SCHEMA TRANSACTION CACHE].freeze
  COUNT_SIGNALS = %w[sql_queries background_jobs emails http_requests errors].freeze

  def call
    warm_runtime
    reset_test_queue

    measurements = COUNT_SIGNALS.index_with(0)
    subscribers = subscribe(measurements)
    started = runtime_snapshot
    Thread.current[RunDiffPortableNetHttpInstrumentation::THREAD_KEY] = 0

    response = request.post(path, headers)
    measurements["http_requests"] += Thread.current[RunDiffPortableNetHttpInstrumentation::THREAD_KEY].to_i
    measurements.merge!(runtime_elapsed(started))

    passed = response.status.between?(200, 299)
    measurements["errors"] += 1 unless passed

    payload = {
      "id" => label,
      "execution_id" => SecureRandom.uuid,
      "run_id" => run_id,
      "scenario_id" => scenario_id,
      "subject" => subject,
      "ref" => label,
      "sha" => sha,
      "status" => passed ? "passed" : "failed",
      "http_status" => response.status,
      "correlation_confirmed" => false,
      "async_correlation_confirmed" => false,
      "measurements" => measurements,
      "attributions" => {},
      "durable_observations" => [],
      "application_job_executions" => [],
      "lifecycle" => {
        "capture_runtime" => "tool_owned_portable_rails",
        "async_transport" => { "name" => "unavailable" },
        "durable_async_evidence" => false
      }
    }

    File.write(ENV.fetch("RUNDIFF_OUTPUT"), JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload)
  rescue StandardError => error
    write_failure(error)
    raise
  ensure
    Thread.current[RunDiffPortableNetHttpInstrumentation::THREAD_KEY] = nil
    subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
    reset_test_queue
  end

  private

  def subscribe(measurements)
    [
      ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        payload = event.payload
        next if payload[:cached]
        next if IGNORED_SQL_NAMES.include?(payload[:name].to_s)

        measurements["sql_queries"] += 1
      end,
      ActiveSupport::Notifications.subscribe("enqueue.active_job") do
        measurements["background_jobs"] += 1
      end,
      ActiveSupport::Notifications.subscribe("enqueue_at.active_job") do
        measurements["background_jobs"] += 1
      end,
      ActiveSupport::Notifications.subscribe("deliver.action_mailer") do
        measurements["emails"] += 1
      end,
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
        payload = event.payload
        measurements["errors"] += 1 if payload[:exception] || payload[:exception_object]
      end
    ]
  end

  def warm_runtime
    request.post(path, headers(warmup: true))
  rescue StandardError
    # Warmup is best effort. The measured request remains authoritative.
  ensure
    reset_test_queue
  end

  def reset_test_queue
    return unless defined?(ActiveJob::Base)

    adapter = ActiveJob::Base.queue_adapter
    adapter.enqueued_jobs.clear if adapter.respond_to?(:enqueued_jobs)
    adapter.performed_jobs.clear if adapter.respond_to?(:performed_jobs)
  end

  def runtime_snapshot
    {
      wall: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      process_cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID),
      thread_cpu: thread_cpu_time
    }
  end

  def runtime_elapsed(started)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started.fetch(:wall)
    process_cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started.fetch(:process_cpu)
    current_thread_cpu = thread_cpu_time
    thread_cpu = if started[:thread_cpu] && current_thread_cpu
      current_thread_cpu - started.fetch(:thread_cpu)
    end

    {
      "duration_ms" => (wall * 1_000).round(1),
      "process_cpu_ms" => (process_cpu * 1_000).round(1),
      "thread_cpu_ms" => thread_cpu && (thread_cpu * 1_000).round(1)
    }.compact
  end

  def thread_cpu_time
    return unless Process.const_defined?(:CLOCK_THREAD_CPUTIME_ID)

    Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
  rescue Errno::EINVAL
    nil
  end

  def write_failure(error)
    output = ENV["RUNDIFF_OUTPUT"]
    return if output.to_s.empty?

    payload = {
      "id" => label,
      "execution_id" => SecureRandom.uuid,
      "run_id" => run_id,
      "scenario_id" => scenario_id,
      "subject" => subject,
      "ref" => label,
      "sha" => sha,
      "status" => "failed",
      "measurements" => COUNT_SIGNALS.index_with(0).merge("errors" => 1),
      "attributions" => {},
      "durable_observations" => [],
      "error" => { "class" => error.class.to_s, "message" => error.message.to_s }
    }
    File.write(output, JSON.pretty_generate(payload))
  rescue StandardError
    nil
  end

  def request
    @request ||= Rack::MockRequest.new(Rails.application)
  end

  def headers(warmup: false)
    {
      "HTTP_HOST" => "localhost",
      "HTTP_X_RUNDIFF_EXECUTION_ID" => warmup ? "warmup" : SecureRandom.uuid,
      "HTTP_X_RUNDIFF_RUN_ID" => run_id,
      "HTTP_X_RUNDIFF_SUBJECT" => subject
    }
  end

  def path
    ENV.fetch("RUNDIFF_SCENARIO_PATH")
  end

  def run_id
    ENV.fetch("RUNDIFF_RUN_ID")
  end

  def scenario_id
    ENV.fetch("RUNDIFF_SCENARIO_ID")
  end

  def subject
    ENV.fetch("RUNDIFF_SUBJECT")
  end

  def label
    ENV.fetch("RUNDIFF_EXECUTION_LABEL")
  end

  def sha
    ENV.fetch("RUNDIFF_EXECUTION_SHA")
  end
end

RunDiffPortableRailsCapture.new.call
