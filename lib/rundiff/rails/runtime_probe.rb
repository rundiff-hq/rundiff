module RunDiff
  module Rails
    class RuntimeProbe
      CLOCKS = {
        wall: :CLOCK_MONOTONIC,
        process_cpu: :CLOCK_PROCESS_CPUTIME_ID,
        thread_cpu: :CLOCK_THREAD_CPUTIME_ID
      }.freeze

      class << self
        def snapshot
          CLOCKS.each_with_object({}) do |(metric, clock_name), result|
            result[metric] = read(clock_name)
          end
        end

        def elapsed_ms(started_at, subtract_seconds: {})
          finished_at = snapshot

          CLOCKS.each_key.each_with_object({}) do |metric, result|
            started = started_at[metric]
            finished = finished_at[metric]
            next if started.nil? || finished.nil?

            elapsed = finished - started - subtract_seconds.fetch(metric, 0.0).to_f
            result[metric] = ([ elapsed, 0.0 ].max * 1000).round(1)
          end
        end

        private

        def read(clock_name)
          return unless Process.const_defined?(clock_name, false)

          Process.clock_gettime(Process.const_get(clock_name, false))
        rescue Errno::EINVAL, NotImplementedError
          nil
        end
      end
    end
  end
end
