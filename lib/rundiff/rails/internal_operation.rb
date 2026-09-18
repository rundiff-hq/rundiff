module RunDiff
  module Rails
    module InternalOperation
      DEPTH_KEY = :rundiff_internal_operation_depth
      METRICS = {
        wall: {
          clock: :CLOCK_MONOTONIC,
          started_key: :rundiff_internal_operation_wall_started_at,
          elapsed_key: :rundiff_internal_operation_wall_elapsed_seconds
        },
        process_cpu: {
          clock: :CLOCK_PROCESS_CPUTIME_ID,
          started_key: :rundiff_internal_operation_process_cpu_started_at,
          elapsed_key: :rundiff_internal_operation_process_cpu_elapsed_seconds
        },
        thread_cpu: {
          clock: :CLOCK_THREAD_CPUTIME_ID,
          started_key: :rundiff_internal_operation_thread_cpu_started_at,
          elapsed_key: :rundiff_internal_operation_thread_cpu_elapsed_seconds
        }
      }.freeze

      class << self
        def call
          previous_depth = depth
          start_outer_operation if previous_depth.zero?
          ActiveSupport::IsolatedExecutionState[DEPTH_KEY] = previous_depth + 1
          yield
        ensure
          finish_outer_operation if previous_depth.to_i.zero?
          restore_depth(previous_depth)
        end

        def active?
          depth.positive?
        end

        def elapsed_seconds
          elapsed_metric(:wall)
        end

        def elapsed_process_cpu_seconds
          elapsed_metric(:process_cpu)
        end

        def elapsed_thread_cpu_seconds
          elapsed_metric(:thread_cpu)
        end

        def snapshot
          {
            wall: elapsed_seconds,
            process_cpu: elapsed_process_cpu_seconds,
            thread_cpu: elapsed_thread_cpu_seconds
          }
        end

        def delta_since(snapshot)
          current = self.snapshot

          current.each_with_object({}) do |(metric, value), result|
            result[metric] = [ value - snapshot.fetch(metric, 0.0).to_f, 0.0 ].max
          end
        end

        private

        def depth
          ActiveSupport::IsolatedExecutionState[DEPTH_KEY].to_i
        end

        def start_outer_operation
          METRICS.each_value do |config|
            ActiveSupport::IsolatedExecutionState[config.fetch(:started_key)] = clock_time(config.fetch(:clock))
          end
        end

        def finish_outer_operation
          METRICS.each_value do |config|
            started_at = ActiveSupport::IsolatedExecutionState.delete(config.fetch(:started_key))
            next unless started_at

            finished_at = clock_time(config.fetch(:clock))
            next unless finished_at

            elapsed_key = config.fetch(:elapsed_key)
            elapsed = ActiveSupport::IsolatedExecutionState[elapsed_key].to_f
            ActiveSupport::IsolatedExecutionState[elapsed_key] = elapsed + (finished_at - started_at)
          end
        end

        def elapsed_metric(metric)
          config = METRICS.fetch(metric)
          accumulated = ActiveSupport::IsolatedExecutionState[config.fetch(:elapsed_key)].to_f
          return accumulated unless active?

          started_at = ActiveSupport::IsolatedExecutionState[config.fetch(:started_key)]
          return accumulated unless started_at

          current = clock_time(config.fetch(:clock))
          return accumulated unless current

          accumulated + (current - started_at)
        end

        def restore_depth(previous_depth)
          if previous_depth.to_i.zero?
            ActiveSupport::IsolatedExecutionState.delete(DEPTH_KEY)
          else
            ActiveSupport::IsolatedExecutionState[DEPTH_KEY] = previous_depth
          end
        end

        def clock_time(clock_name)
          return unless Process.const_defined?(clock_name, false)

          Process.clock_gettime(Process.const_get(clock_name, false))
        rescue Errno::EINVAL, NotImplementedError
          nil
        end
      end
    end
  end
end
