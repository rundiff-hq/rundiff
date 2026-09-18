module RunDiff
  module Rails
    class ExecutionQuiescence
      DEFAULT_TIMEOUT_SECONDS = 5.0
      DEFAULT_POLL_INTERVAL_SECONDS = 0.01
      DEFAULT_QUIET_PERIOD_SECONDS = 0.05

      class TimeoutError < StandardError
        attr_reader :snapshot

        def initialize(snapshot)
          @snapshot = snapshot
          pending = snapshot.fetch("work_items").select { |item| item.fetch("active") }
          summary = pending.map do |item|
            "#{item.fetch("name") || item.fetch("kind")}:#{item.fetch("work_id")}"
          end.join(", ")
          super("Execution #{snapshot.fetch("execution_id")} did not become quiescent; pending: #{summary}")
        end
      end

      class << self
        def wait(execution_id:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
                 poll_interval_seconds: DEFAULT_POLL_INTERVAL_SECONDS,
                 quiet_period_seconds: DEFAULT_QUIET_PERIOD_SECONDS)
          new(
            execution_id:,
            timeout_seconds:,
            poll_interval_seconds:,
            quiet_period_seconds:
          ).wait
        end

        def snapshot(execution_id:)
          new(execution_id:).snapshot
        end
      end

      def initialize(execution_id:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
                     poll_interval_seconds: DEFAULT_POLL_INTERVAL_SECONDS,
                     quiet_period_seconds: DEFAULT_QUIET_PERIOD_SECONDS)
        @execution_id = execution_id.to_s
        @timeout_seconds = Float(timeout_seconds)
        @poll_interval_seconds = Float(poll_interval_seconds)
        @quiet_period_seconds = Float(quiet_period_seconds)
      end

      def wait
        started_at = monotonic_time
        deadline = started_at + timeout_seconds
        quiet_started_at = nil

        loop do
          current_snapshot = snapshot
          now = monotonic_time

          if current_snapshot.fetch("pending_count").zero?
            quiet_started_at ||= now
            if now - quiet_started_at >= quiet_period_seconds
              return current_snapshot.merge(
                "quiescent" => true,
                "waited_ms" => ((now - started_at) * 1000).round(1),
                "quiet_period_ms" => (quiet_period_seconds * 1000).round(1)
              )
            end
          else
            quiet_started_at = nil
          end

          raise TimeoutError.new(current_snapshot) if now >= deadline

          sleep([ poll_interval_seconds, deadline - now ].min)
        end
      end

      def snapshot
        InternalOperation.call do
          work_items = RunDiffExecutionWorkItem.where(execution_id:).order(:id).map do |item|
            {
              "kind" => item.kind,
              "work_id" => item.work_id,
              "name" => item.name,
              "queue_name" => item.queue_name,
              "status" => item.status,
              "active" => item.status.in?(RunDiffExecutionWorkItem::ACTIVE_STATUSES),
              "error_class" => item.error_class
            }
          end

          {
            "execution_id" => execution_id,
            "pending_count" => work_items.count { |item| item.fetch("active") },
            "work_items" => work_items
          }
        end
      end

      private

      attr_reader :execution_id, :timeout_seconds, :poll_interval_seconds, :quiet_period_seconds

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
