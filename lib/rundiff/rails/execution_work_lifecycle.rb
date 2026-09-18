module RunDiff
  module Rails
    class ExecutionWorkLifecycle
      KIND = "active_job".freeze

      class << self
        def enqueued(job, context:)
          execution_id = context["rundiff_execution_id"]
          return if execution_id.blank?

          mutate(execution_id:, job:) do |item, now|
            assign_context(item, context:, job:)
            item.status = "enqueued"
            item.enqueued_at = now
            item.started_at = nil
            item.finished_at = nil
            item.error_class = nil
          end
        end

        def running(job)
          mutate_from_current(job:) do |item, now|
            item.status = "running"
            item.enqueued_at ||= now
            item.started_at ||= now
            item.finished_at = nil
            item.error_class = nil
          end
        end

        def completed(job)
          mutate_from_current(job:) do |item, now|
            item.status = "completed"
            item.enqueued_at ||= now
            item.started_at ||= now
            item.finished_at = now
            item.error_class = nil
          end
        end

        def failed(job, error:)
          mutate_from_current(job:) do |item, now|
            item.status = "failed"
            item.enqueued_at ||= now
            item.started_at ||= now
            item.finished_at = now
            item.error_class = error.class.name
          end
        end

        def quiescent?(execution_id:)
          InternalOperation.call do
            !RunDiffExecutionWorkItem.where(execution_id:).active.exists?
          end
        end

        def pending_count(execution_id:)
          InternalOperation.call do
            RunDiffExecutionWorkItem.where(execution_id:).active.count
          end
        end

        private

        def mutate_from_current(job:)
          execution_id = Current.rundiff_execution_id
          return if execution_id.blank?

          context = {
            "rundiff_execution_id" => execution_id,
            "rundiff_run_id" => Current.rundiff_run_id,
            "rundiff_subject" => Current.rundiff_subject
          }

          mutate(execution_id:, job:) do |item, now|
            assign_context(item, context:, job:)
            yield(item, now)
          end
        end

        def mutate(execution_id:, job:)
          InternalOperation.call do
            item = RunDiffExecutionWorkItem.find_or_initialize_by(
              execution_id: execution_id.to_s,
              kind: KIND,
              work_id: job.job_id.to_s
            )
            now = Time.current
            yield(item, now)
            item.save!
            item
          end
        end

        def assign_context(item, context:, job:)
          item.run_id = context["rundiff_run_id"]&.to_s
          item.subject = context["rundiff_subject"]&.to_s
          item.name = job.class.name
          item.queue_name = job.queue_name
        end
      end
    end
  end
end
