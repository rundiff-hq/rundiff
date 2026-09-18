require "fileutils"
require "rbconfig"
require "tmpdir"

module RunDiff
  module Rails
    class SolidQueueExecution
      DEFAULT_START_TIMEOUT_SECONDS = 10.0
      DEFAULT_QUIESCENCE_TIMEOUT_SECONDS = 10.0
      DEFAULT_QUIET_PERIOD_SECONDS = 0.05

      def self.call(execution_id:, **options)
        new(execution_id:, **options).call
      end

      def initialize(execution_id:, start_timeout_seconds: DEFAULT_START_TIMEOUT_SECONDS,
                     quiescence_timeout_seconds: DEFAULT_QUIESCENCE_TIMEOUT_SECONDS,
                     quiet_period_seconds: DEFAULT_QUIET_PERIOD_SECONDS)
        @execution_id = execution_id.to_s
        @start_timeout_seconds = Float(start_timeout_seconds)
        @quiescence_timeout_seconds = Float(quiescence_timeout_seconds)
        @quiet_period_seconds = Float(quiet_period_seconds)
        @supervisor_pid = nil
        @worker_pids = []
        @directory = nil
        @log_path = nil
      end

      def call
        start
        finish
      ensure
        stop
      end

      def start
        return self if started?

        @directory = Dir.mktmpdir("rundiff-solid-queue-execution")
        @log_path = File.join(@directory, "solid-queue.log")

        File.open(@log_path, "w") do |log|
          @supervisor_pid = Process.spawn(
            worker_environment,
            RbConfig.ruby,
            File.join(::Rails.root, "bin/jobs"),
            "--skip-recurring",
            chdir: ::Rails.root.to_s,
            out: log,
            err: log
          )
        end

        @worker_pids = wait_for_workers
        self
      rescue StandardError
        stop
        raise
      end

      def finish
        raise "Solid Queue execution has not been started" unless started?

        jobs = correlated_queue_jobs
        raise "Expected Solid Queue to contain correlated work for execution #{execution_id}" if jobs.empty?

        validate_serialized_context!(jobs)
        quiescence = ExecutionQuiescence.wait(
          execution_id:,
          timeout_seconds: quiescence_timeout_seconds,
          quiet_period_seconds:
        )
        jobs = correlated_queue_jobs
        validate_serialized_context!(jobs)

        {
          "executions" => execution_provenance(jobs),
          "quiescence" => quiescence,
          "transport" => {
            "name" => "solid_queue",
            "worker_pids" => worker_pids,
            "worker_process_isolated" => worker_pids.none? { |pid| pid == Process.pid },
            "worker_ready_before_execution" => true
          }
        }
      end

      def stop
        status = stop_supervisor
        log = worker_log
        cleanup_directory

        return unless status && !status.success?

        raise "Solid Queue supervisor exited unsuccessfully:\n#{log}"
      end

      def started?
        !@supervisor_pid.nil?
      end

      private

      attr_reader :execution_id, :start_timeout_seconds, :quiescence_timeout_seconds, :quiet_period_seconds,
                  :worker_pids

      def correlated_work_items
        RunDiffExecutionWorkItem.where(execution_id:, kind: "active_job").order(:id)
      end

      def correlated_queue_jobs
        work_ids = correlated_work_items.pluck(:work_id)
        return [] if work_ids.empty?

        SolidQueue::Job.where(active_job_id: work_ids).order(:id).to_a
      end

      def validate_serialized_context!(jobs)
        jobs.each do |job|
          context = job.arguments.fetch(ActiveJobExecutionContext::CONTEXT_KEY)
          raise "Solid Queue job #{job.active_job_id} lost execution id" unless context.fetch("rundiff_execution_id").to_s == execution_id
        end
      end

      def execution_provenance(jobs)
        work_items = correlated_work_items.index_by(&:work_id)

        jobs.map do |job|
          context = job.arguments.fetch(ActiveJobExecutionContext::CONTEXT_KEY)
          work_item = work_items.fetch(job.active_job_id)

          {
            "job_class" => job.class_name,
            "job_id" => job.active_job_id,
            "provider_job_id" => job.id,
            "queue_name" => job.queue_name,
            "execution_id" => context.fetch("rundiff_execution_id"),
            "run_id" => context.fetch("rundiff_run_id"),
            "subject" => context.fetch("rundiff_subject"),
            "source" => "application_enqueue",
            "transport" => "solid_queue",
            "work_status" => work_item.status,
            "transport_finished" => job.finished_at.present?
          }
        end
      end

      def wait_for_workers
        started_at = monotonic_time

        loop do
          pids = SolidQueue::Process.where(kind: "Worker").pluck(:pid)
          return pids if pids.any?

          if (status = reap_supervisor_nonblock)
            raise "Solid Queue supervisor exited before worker registration " \
                  "(status=#{status.exitstatus.inspect}):\n#{worker_log}"
          end

          if monotonic_time - started_at >= start_timeout_seconds
            raise "Solid Queue worker did not register within #{start_timeout_seconds}s:\n#{worker_log}"
          end

          sleep 0.05
        end
      end

      def reap_supervisor_nonblock
        pid = @supervisor_pid
        return unless pid

        waited_pid, status = Process.wait2(pid, Process::WNOHANG)
        return unless waited_pid

        @supervisor_pid = nil
        status
      rescue Errno::ECHILD
        @supervisor_pid = nil
        nil
      end

      def worker_environment
        {
          "RUNDIFF_SOLID_QUEUE" => "1",
          "SOLID_QUEUE_SKIP_RECURRING" => "true",
          "JOB_CONCURRENCY" => "1"
        }
      end

      def stop_supervisor
        pid = @supervisor_pid
        return unless pid

        @supervisor_pid = nil
        Process.kill("TERM", pid)
        _, status = Process.wait2(pid)
        status
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def worker_log
        return "" unless @log_path && File.exist?(@log_path)

        File.read(@log_path)
      end

      def cleanup_directory
        directory = @directory
        @directory = nil
        @log_path = nil
        FileUtils.remove_entry(directory) if directory && File.exist?(directory)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
