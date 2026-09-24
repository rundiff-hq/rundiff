require "digest"

module RunDiff
  module Github
    class ExecutionDispatcher
      DEFAULT_SCENARIO_ID = "dogfood.git.behavior".freeze

      def initialize(
        scenario_id: ENV.fetch("RUNDIFF_SCENARIO_ID", DEFAULT_SCENARIO_ID),
        cancellation: RunDiff::Executor::Cancellation.new
      )
        @scenario_id = scenario_id
        @cancellation = cancellation
      end

      def call(delivery:, pull_request:)
        context = build_context(delivery:, pull_request:)
        execution_id = execution_id_for(context:)
        cancel_superseded_executions!(context:, current_execution_id: execution_id)
        existing = RunDiffExecution.find_by(execution_id:)

        if existing
          return [ existing, true ] if existing.status == "queued"
          return [ existing, true ] if existing.requeue!

          return [ existing, false ]
        end

        execution = RunDiffExecution.create!(
          execution_id:,
          source: "github_pull_request",
          scenario_id: @scenario_id,
          baseline_sha: context.fetch("baseline_sha"),
          candidate_sha: context.fetch("candidate_sha"),
          context:
        )

        [ execution, true ]
      rescue ActiveRecord::RecordNotUnique
        execution = RunDiffExecution.find_by!(execution_id:)
        [ execution, execution.status == "queued" ]
      end

      private

      def cancel_superseded_executions!(context:, current_execution_id:)
        RunDiffExecution
          .where(source: "github_pull_request", status: RunDiffExecution::CANCELLABLE_STATUSES)
          .where("context ->> 'repository' = ?", context.fetch("repository"))
          .where("context ->> 'pull_request_number' = ?", context.fetch("pull_request_number").to_s)
          .where.not(execution_id: current_execution_id)
          .find_each do |execution|
            @cancellation.call(
              execution:,
              reason: "superseded_by_new_pull_request_revision"
            )
          end
      end

      def build_context(delivery:, pull_request:)
        {
          "repository" => delivery.repository,
          "pull_request_number" => delivery.pull_request_number,
          "installation_id" => delivery.installation_id,
          "delivery_id" => delivery.delivery_id,
          "baseline_ref" => pull_request.dig("base", "ref"),
          "baseline_sha" => pull_request.dig("base", "sha"),
          "candidate_ref" => pull_request.dig("head", "ref"),
          "candidate_sha" => pull_request.dig("head", "sha"),
          "candidate_repository" => pull_request.dig("head", "repo", "full_name"),
          "execution_orchestrator" => ENV.fetch("RUNDIFF_EXECUTION_ORCHESTRATOR", "native")
        }
      end

      def execution_id_for(context:)
        identity = [
          context.fetch("repository"),
          context.fetch("pull_request_number"),
          context.fetch("baseline_sha"),
          context.fetch("candidate_sha"),
          @scenario_id
        ].join("\0")

        "github-#{Digest::SHA256.hexdigest(identity)}"
      end
    end
  end
end
