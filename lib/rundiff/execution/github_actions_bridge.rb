module RunDiff
  module Execution
    class GithubActionsBridge
      Error = Class.new(StandardError)
      ClaimNotReady = Class.new(Error)
      InvalidAttempt = Class.new(Error)

      def initialize(
        execution_model: RunDiffExecution,
        finalizer_job: GithubPullRequestExecutionFinalizeJob
      )
        @execution_model = execution_model
        @finalizer_job = finalizer_job
      end

      def claim(repository:, pull_request_number:, baseline_sha:, candidate_sha:)
        execution = matching_execution(
          repository:,
          pull_request_number:,
          baseline_sha:,
          candidate_sha:
        )

        unless execution && execution.status == "running" && !execution.lease_expired?
          raise ClaimNotReady, "Matching RunDiff execution is not ready"
        end

        RunDiff::Executor::Request.from_execution(execution)
      end

      def submit_result(execution_id:, attempt_number:, result_payload:)
        execution = @execution_model.find_by(execution_id:)
        raise InvalidAttempt, "RunDiff execution was not found" unless execution

        expected_attempt = Integer(attempt_number)
        unless execution.attempt_count == expected_attempt
          raise InvalidAttempt, "RunDiff execution attempt does not match"
        end

        unless RunDiffExecution::LEASED_STATUSES.include?(execution.status) && !execution.lease_expired?
          raise InvalidAttempt, "RunDiff execution attempt is no longer live"
        end

        result = RunDiff::Executor::Result.from_h(result_payload)
        @finalizer_job.perform_later(execution.execution_id, result.to_h)
        result
      end

      private

      def matching_execution(repository:, pull_request_number:, baseline_sha:, candidate_sha:)
        @execution_model
          .where(
            source: "github_pull_request",
            status: "running",
            baseline_sha: baseline_sha.to_s,
            candidate_sha: candidate_sha.to_s
          )
          .where("context ->> 'repository' = ?", repository.to_s)
          .where("context ->> 'pull_request_number' = ?", Integer(pull_request_number).to_s)
          .where("context ->> 'execution_orchestrator' = ?", "github_actions")
          .order(created_at: :desc)
          .first
      end
    end
  end
end
