#!/usr/bin/env ruby

require "json"
require "rack/mock"
require "rbconfig"
require "securerandom"
require "tmpdir"

require File.join(Dir.pwd, "config/environment")

PATH = "/__rundiff/demo/process-proof".freeze
START_TIMEOUT_SECONDS = 10.0

unless ActiveJob::Base.queue_adapter.class.name.include?("SolidQueue")
  raise "Solid Queue proof requires RUNDIFF_SOLID_QUEUE=1"
end

begin
  Current.reset
  RunDiffEvidenceEvent.delete_all
  RunDiffExecutionWorkItem.delete_all

  execution_id = SecureRandom.uuid
  run_id = "solid-queue-proof-#{SecureRandom.hex(4)}"
  headers = {
    "HTTP_HOST" => "localhost",
    "HTTP_X_RUNDIFF_EXECUTION_ID" => execution_id,
    "HTTP_X_RUNDIFF_RUN_ID" => run_id,
    "HTTP_X_RUNDIFF_SUBJECT" => "solid-queue-proof"
  }

  response = Rack::MockRequest.new(Rails.application).post(PATH, headers)
  raise "Solid Queue proof request failed with HTTP #{response.status}" unless response.status.between?(200, 299)
  raise "Request process leaked RunDiff Current state" if Current.rundiff_execution_id

  response_payload = JSON.parse(response.body)
  job_id = response_payload.fetch("job_id")
  queue_job = SolidQueue::Job.find_by!(active_job_id: job_id)
  serialized_context = queue_job.arguments.fetch(RunDiff::Rails::ActiveJobExecutionContext::CONTEXT_KEY)

  raise "Solid Queue payload lost execution id" unless serialized_context.fetch("rundiff_execution_id") == execution_id
  raise "Solid Queue payload lost run id" unless serialized_context.fetch("rundiff_run_id") == run_id
  raise "Solid Queue payload lost subject" unless serialized_context.fetch("rundiff_subject") == "solid-queue-proof"

  work_item = RunDiffExecutionWorkItem.find_by!(execution_id:, kind: "active_job", work_id: job_id)
  raise "Work item must be enqueued before Solid Queue worker starts" unless work_item.status == "enqueued"

  supervisor_pid = nil
  supervisor_status = nil
  worker_pids = []
  quiescence = nil
  worker_log = nil

  Dir.mktmpdir("rundiff-solid-queue-proof") do |directory|
    log_path = File.join(directory, "solid-queue.log")
    worker_env = {
      "RUNDIFF_SOLID_QUEUE" => "1",
      "SOLID_QUEUE_SKIP_RECURRING" => "true",
      "JOB_CONCURRENCY" => "1"
    }

    File.open(log_path, "w") do |log|
      supervisor_pid = Process.spawn(
        worker_env,
        RbConfig.ruby,
        File.expand_path("../bin/jobs", __dir__),
        "--skip-recurring",
        chdir: Dir.pwd,
        out: log,
        err: log
      )
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      worker_pids = SolidQueue::Process.where(kind: "Worker").pluck(:pid)
      break if worker_pids.any?

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at >= START_TIMEOUT_SECONDS
        raise "Solid Queue worker did not register within #{START_TIMEOUT_SECONDS}s"
      end

      sleep 0.05
    end

    raise "Solid Queue worker shares the request process PID" if worker_pids.include?(Process.pid)
    raise "Solid Queue worker shares the supervisor PID" if worker_pids.include?(supervisor_pid)

    quiescence = RunDiff::Rails::ExecutionQuiescence.wait(
      execution_id:,
      timeout_seconds: 10.0,
      quiet_period_seconds: 0.05
    )

    Process.kill("TERM", supervisor_pid)
    _, supervisor_status = Process.wait2(supervisor_pid)
    supervisor_pid = nil
    worker_log = File.read(log_path)
  ensure
    if supervisor_pid
      begin
        Process.kill("TERM", supervisor_pid)
        Process.wait(supervisor_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  raise "Solid Queue supervisor exited unsuccessfully:\n#{worker_log}" unless supervisor_status&.success?
  raise "Execution did not reach durable quiescence" unless quiescence.fetch("quiescent")
  raise "Execution still has pending work" unless quiescence.fetch("pending_count").zero?
  raise "Request process gained RunDiff Current state from worker" if Current.rundiff_execution_id

  completed_work = RunDiffExecutionWorkItem.find_by!(execution_id:, kind: "active_job", work_id: job_id)
  raise "Solid Queue work item did not complete" unless completed_work.status == "completed"

  evidence = RunDiffEvidenceEvent.where(execution_id:, producer_id: job_id).order(:id)
  signals = evidence.map(&:signal)
  %w[queue_wait_ms scheduled_delay_ms dispatch_wait_ms sql_queries emails http_requests].each do |signal|
    raise "Solid Queue worker did not persist #{signal} evidence" unless signals.include?(signal)
  end

  queue_stage_values = evidence.where(signal: %w[queue_wait_ms scheduled_delay_ms dispatch_wait_ms]).each_with_object({}) do |record, values|
    values[record.signal] = record.payload.fetch("value")
  end
  unless (queue_stage_values.fetch("queue_wait_ms") - queue_stage_values.fetch("scheduled_delay_ms") - queue_stage_values.fetch("dispatch_wait_ms")).abs <= 0.1
    raise "Solid Queue stage decomposition does not add up"
  end

  queue_job.reload
  raise "Solid Queue job did not finish" if queue_job.finished_at.nil?

  report = {
    "request_process_pid" => Process.pid,
    "solid_queue_worker_pids" => worker_pids,
    "execution_id" => execution_id,
    "run_id" => run_id,
    "job_id" => job_id,
    "solid_queue_job_id" => queue_job.id,
    "serialized_context" => serialized_context,
    "pre_worker_status" => "enqueued",
    "final_work_status" => completed_work.status,
    "evidence_signals" => signals,
    "queue_stages" => queue_stage_values,
    "quiescence" => quiescence,
    "request_current_after_worker" => {
      "execution_id" => Current.rundiff_execution_id,
      "run_id" => Current.rundiff_run_id,
      "subject" => Current.rundiff_subject
    },
    "transport" => "solid_queue",
    "queue_job_finished" => true,
    "worker_log_tail" => worker_log.lines.last(12).join
  }

  puts JSON.pretty_generate(report)
ensure
  Current.reset
end
