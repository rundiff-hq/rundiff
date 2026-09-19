module RunDiff
  module Runtime
    class QueueHealth
      HEARTBEAT_WINDOW = 60.seconds

      def initialize(
        process_model: SolidQueue::Process,
        job_model: SolidQueue::Job,
        ready_model: SolidQueue::ReadyExecution,
        claimed_model: SolidQueue::ClaimedExecution,
        failed_model: SolidQueue::FailedExecution,
        clock: -> { Time.current }
      )
        @process_model = process_model
        @job_model = job_model
        @ready_model = ready_model
        @claimed_model = claimed_model
        @failed_model = failed_model
        @clock = clock
      end

      def call
        cutoff = @clock.call - HEARTBEAT_WINDOW
        control_jobs = @job_model.where(queue_name: "control")
        unfinished_control_jobs = control_jobs.where(finished_at: nil)

        live_processes = @process_model
          .where("last_heartbeat_at >= ?", cutoff)
          .order(:kind, :name)
          .pluck(:kind, :name, :last_heartbeat_at)

        {
          "status" => "available",
          "adapter" => "solid_queue",
          "heartbeat_window_seconds" => HEARTBEAT_WINDOW.to_i,
          "live_processes" => live_processes.map do |kind, name, last_heartbeat_at|
            {
              "kind" => kind,
              "name" => name,
              "last_heartbeat_at" => last_heartbeat_at&.utc&.iso8601
            }
          end,
          "pending_control_jobs" => unfinished_control_jobs.count,
          "ready_control_jobs" => @ready_model.where(queue_name: "control").count,
          "claimed_control_jobs" => @claimed_model.where(job_id: unfinished_control_jobs.select(:id)).count,
          "failed_control_jobs" => @failed_model.where(job_id: control_jobs.select(:id)).count
        }
      rescue StandardError => error
        {
          "status" => "unavailable",
          "adapter" => "solid_queue",
          "error_class" => error.class.name
        }
      end
    end
  end
end
