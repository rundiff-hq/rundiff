#!/usr/bin/env ruby

require "json"
require "rack/mock"
require "rbconfig"
require "securerandom"
require "tmpdir"

require File.join(Dir.pwd, "config/environment")

PATH = "/__rundiff/demo/process-proof".freeze

begin
  Current.reset
  RunDiffEvidenceEvent.delete_all
  RunDiffExecutionWorkItem.delete_all
  adapter = ActiveJob::Base.queue_adapter
  adapter.enqueued_jobs.clear
  adapter.performed_jobs.clear if adapter.respond_to?(:performed_jobs)

  execution_id = SecureRandom.uuid
  run_id = "os-process-proof-#{SecureRandom.hex(4)}"
  headers = {
    "HTTP_HOST" => "localhost",
    "HTTP_X_RUNDIFF_EXECUTION_ID" => execution_id,
    "HTTP_X_RUNDIFF_RUN_ID" => run_id,
    "HTTP_X_RUNDIFF_SUBJECT" => "os-process-proof"
  }

  response = Rack::MockRequest.new(Rails.application).post(PATH, headers)
  raise "Process proof request failed with HTTP #{response.status}" unless response.status.between?(200, 299)
  raise "Request process leaked RunDiff Current state" if Current.rundiff_execution_id

  response_payload = JSON.parse(response.body)
  job_id = response_payload.fetch("job_id")

  serialized_job = lambda do |job_data|
    job_data.each_with_object({}) do |(key, value), result|
      result[key] = value if key.is_a?(String)
    end
  end

  job_data = adapter.enqueued_jobs.find do |candidate|
    serialized_job.call(candidate).fetch("job_id", nil).to_s == job_id.to_s
  end
  raise "Request did not enqueue the expected ActiveJob payload" unless job_data

  payload = serialized_job.call(job_data)
  context = payload.fetch(RunDiff::Rails::ActiveJobExecutionContext::CONTEXT_KEY)
  raise "Serialized job lost execution id" unless context.fetch("rundiff_execution_id") == execution_id
  raise "Serialized job lost run id" unless context.fetch("rundiff_run_id") == run_id
  raise "Serialized job lost subject" unless context.fetch("rundiff_subject") == "os-process-proof"

  adapter.enqueued_jobs.delete(job_data)
  work_item = RunDiffExecutionWorkItem.find_by!(execution_id:, kind: "active_job", work_id: job_id)
  raise "Work item must be enqueued before worker process starts" unless work_item.status == "enqueued"

  worker_pid = nil
  worker_status = nil
  worker_report = nil
  quiescence = nil
  worker_log = nil

  Dir.mktmpdir("rundiff-os-process-proof") do |directory|
    payload_path = File.join(directory, "job.json")
    output_path = File.join(directory, "worker.json")
    log_path = File.join(directory, "worker.log")
    File.write(payload_path, JSON.pretty_generate(payload))

    worker_script = File.expand_path("rundiff_worker_process.rb", __dir__)
    worker_env = {
      "RUNDIFF_JOB_PAYLOAD" => payload_path,
      "RUNDIFF_WORKER_OUTPUT" => output_path
    }

    File.open(log_path, "w") do |log|
      worker_pid = Process.spawn(worker_env, RbConfig.ruby, worker_script, chdir: Dir.pwd, out: log, err: log)
    end

    begin
      quiescence = RunDiff::Rails::ExecutionQuiescence.wait(
        execution_id:,
        timeout_seconds: 10.0,
        quiet_period_seconds: 0.05
      )
      _, worker_status = Process.wait2(worker_pid)
      worker_pid = nil
    ensure
      if worker_pid
        begin
          Process.kill("TERM", worker_pid)
          Process.wait(worker_pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end

    worker_log = File.read(log_path)
    raise "Worker process failed:\n#{worker_log}" unless worker_status&.success?
    raise "Worker process did not write its proof report" unless File.exist?(output_path)

    worker_report = JSON.parse(File.read(output_path))
  end

  raise "Worker unexpectedly shared the request process PID" if worker_report.fetch("worker_pid") == Process.pid
  raise "Worker was not spawned as a distinct child process" unless worker_report.fetch("parent_pid") == Process.pid
  raise "Worker boot was not clean" if worker_report.fetch("current_before").values.any?
  raise "Worker leaked Current after job execution" if worker_report.fetch("current_after").values.any?
  raise "Worker did not observe the request execution id" unless worker_report.fetch("observed_execution_ids").include?(execution_id)
  raise "Execution did not reach durable quiescence" unless quiescence.fetch("quiescent")
  raise "Execution still has pending work" unless quiescence.fetch("pending_count").zero?
  raise "Request process gained RunDiff Current state from worker" if Current.rundiff_execution_id

  signals = worker_report.fetch("evidence_signals")
  %w[queue_wait_ms scheduled_delay_ms dispatch_wait_ms sql_queries emails http_requests].each do |signal|
    raise "Worker did not persist #{signal} evidence" unless signals.include?(signal)
  end

  report = {
    "request_process_pid" => Process.pid,
    "execution_id" => execution_id,
    "run_id" => run_id,
    "serialized_context" => context,
    "pre_worker_status" => "enqueued",
    "worker" => worker_report,
    "quiescence" => quiescence,
    "request_current_after_worker" => {
      "execution_id" => Current.rundiff_execution_id,
      "run_id" => Current.rundiff_run_id,
      "subject" => Current.rundiff_subject
    },
    "worker_log" => worker_log.lines.last(8).join
  }

  puts JSON.pretty_generate(report)
ensure
  Current.reset
end
