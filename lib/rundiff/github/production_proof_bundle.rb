require "time"

module RunDiff
  module Github
    class ProductionProofBundle
      Error = Class.new(StandardError)
      SCHEMA_VERSION = "2"
      PHASES = {
        "block" => {
          outcome: "block",
          recommendation: "block",
          conclusion: "failure",
          webhook_action: "opened"
        },
        "allow" => {
          outcome: "allow",
          recommendation: "allow",
          conclusion: "success",
          webhook_action: "synchronize"
        }
      }.freeze

      def initialize(
        repository:,
        pull_request:,
        authentication: AppAuthentication.from_env(root: Rails.root),
        client_factory: nil,
        check_name: ENV.fetch("RUNDIFF_GITHUB_APP_CHECK_NAME", CheckRenderer::NAME),
        bot_login: ENV["RUNDIFF_GITHUB_APP_BOT_LOGIN"],
        control_plane_url: ENV.fetch("RUNDIFF_PUBLIC_URL", "https://app.rundiff.com"),
        executor_url: ENV.fetch("RUNDIFF_REMOTE_EXECUTOR_URL", "https://executor.rundiff.com"),
        app_slug: ENV.fetch("RUNDIFF_GITHUB_APP_SLUG"),
        clock: -> { Time.now.utc }
      )
        @repository = repository.to_s
        @pull_request_number = Integer(pull_request)
        @authentication = authentication
        @client_factory = client_factory || ->(token:) { ProofEvidenceClient.new(token: token.value) }
        @check_name = check_name
        @bot_login = bot_login
        @control_plane_url = control_plane_url
        @executor_url = executor_url
        @app_slug = app_slug
        @clock = clock
      end

      def call
        validate_repository!

        block_execution, allow_execution = transition_executions!
        installation_id = validate_transition!(block_execution:, allow_execution:)
        client = proof_client(installation_id:)
        pull_request = client.pull_request(repository: @repository, number: @pull_request_number)
        validate_current_head!(execution: allow_execution, pull_request:)
        repository_id = Integer(pull_request.dig("base", "repo", "id"))
        github_deliveries = @authentication.webhook_deliveries

        block_proof = build_phase_proof(
          execution: block_execution,
          client:,
          expectation: PHASES.fetch("block"),
          repository_id:,
          github_deliveries:
        )
        allow_proof = build_phase_proof(
          execution: allow_execution,
          client:,
          expectation: PHASES.fetch("allow"),
          repository_id:,
          github_deliveries:
        )

        comment = exact_comment(client:)
        validate_comment!(comment:, expectation: PHASES.fetch("allow"))

        installation_received_at = installation_received_at([ installation_id ])
        first_review_at = [
          parse_time(block_proof.dig("check_run", "completed_at")),
          parse_time(comment["created_at"])
        ].compact.min

        {
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => @clock.call.utc.iso8601(6),
          "repository" => @repository,
          "control_plane_url" => @control_plane_url,
          "executor_url" => @executor_url,
          "github_app_slug" => @app_slug,
          "installation_ids" => [ installation_id ],
          "installation_received_at" => installation_received_at&.utc&.iso8601(6),
          "first_review_at" => first_review_at&.utc&.iso8601(6),
          "install_to_first_review_ms" => elapsed_ms(installation_received_at, first_review_at),
          "transition" => {
            "pull_request_number" => @pull_request_number,
            "pull_request_url" => pull_request["html_url"] || "https://github.com/#{@repository}/pull/#{@pull_request_number}",
            "baseline_sha" => allow_execution.baseline_sha,
            "candidate_ref" => allow_execution.context.fetch("candidate_ref"),
            "block_candidate_sha" => block_execution.candidate_sha,
            "allow_candidate_sha" => allow_execution.candidate_sha
          },
          "proofs" => {
            "block" => block_proof,
            "allow" => allow_proof
          },
          "durable_comment" => {
            "id" => comment.fetch("id"),
            "url" => comment["html_url"],
            "created_at" => comment["created_at"],
            "updated_at" => comment["updated_at"],
            "current_recommendation" => "ALLOW"
          }
        }
      end

      private

      def validate_repository!
        owner, name = @repository.split("/", 2)
        if owner.to_s.empty? || name.to_s.empty? || name.include?("/")
          raise Error, "repository must use owner/name form"
        end
        if owner.casecmp?("rundiff-hq")
          raise Error, "production proof repository must be owned outside rundiff-hq"
        end
        unless @pull_request_number.positive?
          raise Error, "pull request number must be positive"
        end
      end

      def transition_executions!
        executions = RunDiffExecution
          .where(source: "github_pull_request")
          .where("context ->> 'repository' = ?", @repository)
          .where("context ->> 'pull_request_number' = ?", @pull_request_number.to_s)
          .where(status: "completed")
          .order(created_at: :asc)
          .to_a

        allow_execution = executions.reverse.find do |execution|
          execution_matches?(execution, PHASES.fetch("allow"))
        end
        allow_execution || raise(
          Error,
          "no completed ALLOW execution found for #{@repository}##{@pull_request_number}"
        )

        block_execution = executions.reverse.find do |execution|
          execution.created_at <= allow_execution.created_at &&
            execution_matches?(execution, PHASES.fetch("block")) &&
            same_transition_identity?(execution, allow_execution)
        end
        block_execution || raise(
          Error,
          "no earlier BLOCK execution found for #{@repository}##{@pull_request_number} on the same branch/baseline"
        )

        [ block_execution, allow_execution ]
      end

      def execution_matches?(execution, expectation)
        execution.outcome == expectation.fetch(:outcome) &&
          execution.result.dig("result", "merge_recommendation") == expectation.fetch(:recommendation)
      end

      def same_transition_identity?(left, right)
        left.baseline_sha == right.baseline_sha &&
          left.context["candidate_ref"].to_s != "" &&
          left.context["candidate_ref"] == right.context["candidate_ref"] &&
          left.context["candidate_repository"] == right.context["candidate_repository"] &&
          left.context["installation_id"].to_s == right.context["installation_id"].to_s
      end

      def validate_transition!(block_execution:, allow_execution:)
        if block_execution.execution_id == allow_execution.execution_id
          raise Error, "BLOCK and ALLOW proof must use different executions"
        end
        if block_execution.candidate_sha == allow_execution.candidate_sha
          raise Error, "BLOCK and ALLOW proof must use different candidate SHAs"
        end
        if block_execution.created_at > allow_execution.created_at
          raise Error, "BLOCK execution must precede ALLOW execution"
        end

        installation_id = Integer(allow_execution.context.fetch("installation_id"))
        block_installation_id = Integer(block_execution.context.fetch("installation_id"))
        unless block_installation_id == installation_id
          raise Error, "BLOCK and ALLOW executions use different GitHub App installations"
        end

        installation_id
      end

      def proof_client(installation_id:)
        token = @authentication.installation_token(
          installation_id:,
          repositories: [ @repository.split("/", 2).last ]
        )
        @client_factory.call(token:)
      end

      def build_phase_proof(execution:, client:, expectation:, repository_id:, github_deliveries:)
        validate_execution!(execution:, expectation:)
        installation_id = Integer(execution.context.fetch("installation_id"))
        delivery = delivery_for(execution:)
        validate_delivery!(
          delivery:,
          execution:,
          installation_id:,
          expected_action: expectation.fetch(:webhook_action)
        )
        github_delivery = exact_github_delivery(
          deliveries: github_deliveries,
          delivery:,
          installation_id:,
          repository_id:,
          expected_action: expectation.fetch(:webhook_action)
        )

        check_run = exact_check_run(client:, execution:)
        validate_check!(check_run:, expectation:)

        {
          "pull_request_number" => @pull_request_number,
          "baseline_sha" => execution.baseline_sha,
          "candidate_sha" => execution.candidate_sha,
          "candidate_ref" => execution.context.fetch("candidate_ref"),
          "installation_id" => installation_id,
          "webhook_delivery_id" => delivery.delivery_id,
          "webhook_action" => delivery.action,
          "github_delivery" => {
            "id" => github_delivery.fetch("id"),
            "guid" => github_delivery.fetch("guid"),
            "delivered_at" => github_delivery["delivered_at"],
            "redelivery" => github_delivery.fetch("redelivery", false),
            "status_code" => github_delivery.fetch("status_code")
          },
          "execution_id" => execution.execution_id,
          "execution_status" => execution.status,
          "outcome" => execution.outcome,
          "check_run" => {
            "id" => check_run.fetch("id"),
            "name" => check_run.fetch("name"),
            "conclusion" => check_run.fetch("conclusion"),
            "url" => check_run["html_url"],
            "completed_at" => check_run["completed_at"]
          },
          "execution_created_at" => execution.created_at&.utc&.iso8601(6),
          "execution_finished_at" => execution.finished_at&.utc&.iso8601(6)
        }
      end

      def validate_execution!(execution:, expectation:)
        unless execution.status == "completed"
          raise Error, "execution #{execution.execution_id} is #{execution.status}, expected completed"
        end
        unless execution.outcome == expectation.fetch(:outcome)
          raise Error,
            "execution #{execution.execution_id} outcome is #{execution.outcome.inspect}, " \
            "expected #{expectation.fetch(:outcome).inspect}"
        end

        recommendation = execution.result.dig("result", "merge_recommendation")
        unless recommendation == expectation.fetch(:recommendation)
          raise Error,
            "execution #{execution.execution_id} recommendation is #{recommendation.inspect}, " \
            "expected #{expectation.fetch(:recommendation).inspect}"
        end
      end

      def delivery_for(execution:)
        delivery_id = execution.context.fetch("delivery_id")
        GithubWebhookDelivery.find_by(delivery_id:) ||
          raise(Error, "webhook delivery #{delivery_id.inspect} is missing")
      end

      def validate_delivery!(delivery:, execution:, installation_id:, expected_action:)
        if delivery.delivery_id.to_s.start_with?("rundiff-replay-")
          raise Error, "production proof cannot use an operator replay delivery"
        end

        expected = {
          event: "pull_request",
          action: expected_action,
          repository: @repository,
          pull_request_number: @pull_request_number,
          installation_id:,
          base_sha: execution.baseline_sha,
          head_sha: execution.candidate_sha
        }
        actual = expected.keys.to_h { |key| [ key, delivery.public_send(key) ] }

        unless delivery.status == "completed"
          raise Error, "webhook delivery #{delivery.delivery_id} is #{delivery.status}, expected completed"
        end

        return if actual == expected

        raise Error, "webhook delivery #{delivery.delivery_id} does not match execution #{execution.execution_id}"
      end

      def exact_github_delivery(deliveries:, delivery:, installation_id:, repository_id:, expected_action:)
        matches = Array(deliveries).select do |candidate|
          candidate["guid"] == delivery.delivery_id &&
            candidate["event"] == "pull_request" &&
            candidate["action"] == expected_action &&
            Integer(candidate["installation_id"]) == installation_id &&
            Integer(candidate["repository_id"]) == repository_id &&
            candidate["status_code"].to_i.between?(200, 399)
        rescue ArgumentError, TypeError
          false
        end

        if matches.empty?
          raise Error,
            "webhook delivery #{delivery.delivery_id.inspect} was not found in recent authenticated GitHub App delivery history"
        end

        matches.max_by { |candidate| parse_time(candidate["delivered_at"]) || Time.at(0).utc }
      end

      def validate_current_head!(execution:, pull_request:)
        current_base = pull_request.dig("base", "sha")
        current_head = pull_request.dig("head", "sha")
        return if current_base == execution.baseline_sha && current_head == execution.candidate_sha

        raise Error,
          "current PR head/base does not match final ALLOW execution #{execution.execution_id}: " \
          "recorded=#{execution.baseline_sha}...#{execution.candidate_sha} " \
          "current=#{current_base}...#{current_head}"
      end

      def exact_check_run(client:, execution:)
        matches = client
          .check_runs(repository: @repository, head_sha: execution.candidate_sha, name: @check_name)
          .select { |check_run| check_run["external_id"] == execution.execution_id }

        unless matches.one?
          raise Error,
            "expected one #{@check_name.inspect} Check Run for execution #{execution.execution_id}, found #{matches.length}"
        end

        matches.first
      end

      def validate_check!(check_run:, expectation:)
        return if check_run["status"] == "completed" &&
          check_run["conclusion"] == expectation.fetch(:conclusion)

        raise Error,
          "Check Run #{check_run["id"]} is status=#{check_run["status"].inspect} " \
          "conclusion=#{check_run["conclusion"].inspect}, expected completed/#{expectation.fetch(:conclusion)}"
      end

      def exact_comment(client:)
        matches = client.comments(repository: @repository, number: @pull_request_number).select do |comment|
          marker = comment.fetch("body", "").include?(CommentRenderer::MARKER)
          author = @bot_login.to_s.empty? || comment.dig("user", "login") == @bot_login
          marker && author
        end

        unless matches.one?
          raise Error,
            "expected one durable RunDiff comment on #{@repository}##{@pull_request_number}, found #{matches.length}"
        end

        matches.first
      end

      def validate_comment!(comment:, expectation:)
        expected = expectation.fetch(:recommendation).upcase
        return if comment.fetch("body", "").include?("**#{expected}**")

        raise Error, "RunDiff comment #{comment["id"]} does not contain expected #{expected} recommendation"
      end

      def installation_received_at(installation_ids)
        return if installation_ids.empty?

        GithubWebhookDelivery
          .where(event: "installation", installation_id: installation_ids)
          .minimum(:created_at)
      end

      def elapsed_ms(started_at, finished_at)
        return unless started_at && finished_at
        return if finished_at < started_at

        ((finished_at - started_at) * 1_000).round
      end

      def parse_time(value)
        return value if value.respond_to?(:utc)
        return if value.to_s.empty?

        Time.iso8601(value)
      end
    end
  end
end
