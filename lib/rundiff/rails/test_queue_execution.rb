module RunDiff
  module Rails
    class TestQueueExecution
      DEFAULT_MAX_JOBS = 1_000

      def self.drain(execution_id:, adapter: ActiveJob::Base.queue_adapter, max_jobs: DEFAULT_MAX_JOBS)
        new(execution_id:, adapter:, max_jobs:).drain
      end

      def initialize(execution_id:, adapter:, max_jobs:)
        @execution_id = execution_id.to_s
        @adapter = adapter
        @max_jobs = Integer(max_jobs)
      end

      def drain
        executions = []
        Current.reset

        loop do
          jobs = matching_jobs
          break if jobs.empty?

          if executions.size + jobs.size > @max_jobs
            raise "Execution #{@execution_id} exceeded #{@max_jobs} correlated TestAdapter jobs"
          end

          jobs.each { |job_data| @adapter.enqueued_jobs.delete(job_data) }
          executions.concat(jobs.map { |job_data| execute(job_data) })
        end

        executions
      ensure
        Current.reset
      end

      private

      def execute(job_data)
        serialized = serialized_job(job_data)
        context = serialized.fetch(ActiveJobExecutionContext::CONTEXT_KEY, {})

        ActiveJob::Base.execute(serialized)

        {
          "job_class" => serialized.fetch("job_class"),
          "job_id" => serialized.fetch("job_id"),
          "queue_name" => serialized.fetch("queue_name"),
          "execution_id" => context["rundiff_execution_id"],
          "run_id" => context["rundiff_run_id"],
          "subject" => context["rundiff_subject"],
          "source" => "application_enqueue"
        }
      ensure
        Current.reset
      end

      def matching_jobs
        @adapter.enqueued_jobs.select do |job_data|
          context = serialized_job(job_data)[ActiveJobExecutionContext::CONTEXT_KEY]
          context&.fetch("rundiff_execution_id", nil).to_s == @execution_id
        end
      end

      def serialized_job(job_data)
        job_data.each_with_object({}) do |(key, value), result|
          result[key] = value if key.is_a?(String)
        end
      end
    end
  end
end
