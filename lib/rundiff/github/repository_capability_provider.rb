module RunDiff
  module Github
    class RepositoryCapabilityProvider
      Error = Class.new(StandardError)

      def initialize(root: ::Rails.root, execution_model: RunDiffExecution, authentication: nil)
        @root = root
        @execution_model = execution_model
        @authentication = authentication
      end

      def call(request:)
        execution = @execution_model.find_by(execution_id: request.execution_id)
        return unless execution

        installation_id = execution.context["installation_id"]
        return unless installation_id

        assert_active_execution!(execution:)
        assert_request_matches_execution!(request:, execution:)

        repository = execution.context.fetch("repository")
        owner, name = repository.split("/", 2)
        raise Error, "Executor repository must use owner/name form" if owner.to_s.empty? || name.to_s.empty?

        token = authentication.installation_token(
          installation_id:,
          repositories: [ name ],
          permissions: { contents: "read" }
        )

        RunDiff::Executor::RepositoryCapability.new(token: token.value)
      end

      private

      def assert_active_execution!(execution:)
        unless execution.status == "running" && !execution.lease_expired?
          raise Error, "Repository capability can only be minted for a live running execution"
        end
      end

      def assert_request_matches_execution!(request:, execution:)
        recorded = execution.context
        matches = request.scenario_id == execution.scenario_id &&
          request.baseline_sha == execution.baseline_sha &&
          request.candidate_sha == execution.candidate_sha &&
          request.attempt_number == execution.attempt_count &&
          request.context["repository"] == recorded["repository"] &&
          request.context["candidate_repository"] == recorded["candidate_repository"] &&
          Integer(request.context["pull_request_number"]) == Integer(recorded["pull_request_number"])

        raise Error, "Repository capability request does not match the durable execution attempt" unless matches
      rescue ArgumentError, TypeError
        raise Error, "Repository capability request does not match the durable execution attempt"
      end

      def authentication
        @authentication ||= AppAuthentication.from_env(root: @root)
      end
    end
  end
end
