require "time"

module RunDiff
  module Github
    class ProductionProofBundle
      Error = Class.new(StandardError)
      SCHEMA_VERSION = "1"
      PROOFS = {
        "regression" => {
          outcome: "block",
          recommendation: "block",
          conclusion: "failure"
        },
        "neutral" => {
          outcome: "allow",
          recommendation: "allow",
          conclusion: "success"
        }
      }.freeze

      def initialize(
        repository:,
        regression_pr:,
        neutral_pr:,
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
        @proof_prs = {
          "regression" => Integer(regression_pr),
          "neutral" => Integer(neutral_pr)
        }.freeze
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

        proofs = PROOFS.to_h do |label, expectation|
          [
            label,
            build_proof(
              number: @proof_prs.fetch(label),
              expectation:
            )
          ]
        end

        installation_ids = proofs.values.map { |proof| proof.fetch("installation_id") }.uniq.sort
        installation_received_at = installation_received_at(installation_ids)
        first_review_at = proofs.values.filter_map { |proof| parse_time(proof["first_review_at"]) }.min

        {
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => @clock.call.utc.iso8601(6),
          "repository" => @repository,
          "control_plane_url" => @control_plane_url,
          "executor_url" => @executor_url,
          "github_app_slug" => @app_slug,
          "installation_ids" => installation_ids,
          "installation_received_at" => installation_received_at&.utc&.iso8601(6),
          "first_review_at" => first_review_at&.utc&.iso8601(6),
          "install_to_first_review_ms" => elapsed_ms(installation_received_at, first_review_at),
          "proofs" => proofs
        }
      end

      private

      def validate_repository!
        owner, name = @repository.split("/", 2)
        if owner.to_s.empty? || name.to_s.empty?
          raise Error, "repository must use owner/name form"
        end
        if owner.casecmp?("rundiff-hq")
          raise Error, "production proof repository must be owned outside rundiff-hq"
        end
      end

      def build_proof(number:, expectation:)
        execution = execution_for(number:)
        validate_execution!(execution:, expectation:)

        context = execution.context
        installation_id = Integer(context.fetch("installation_id"))
        delivery = delivery_for(execution:)
        validate_delivery!(delivery:, execution:, installation_id:)

        token = @authentication.installation_token(
          installation_id:,
          repositories: [ @repository.split("/", 2).last ]
        )
        client = @client_factory.call(token:)
        pull_request = client.pull_request(repository: @repository, number:)
        validate_current_head!(execution:, pull_request:)

        check_run = exact_check_run(client:, execution:)
        validate_check!(check_run:, expectation:)
        comment = exact_comment(client:, number:)
        validate_comment!(comment:, expectation:)

        first_review_at = [
          parse_time(check_run["completed_at"]),
          parse_time(comment["created_at"])
        ].compact.min

        {
          "pull_request_number" => number,
          "pull_request_url" => pull_request["html_url"] || "https://github.com/#{@repository}/pull/#{number}",
          "baseline_sha" => execution.baseline_sha,
          "candidate_sha" => execution.candidate_sha,
          "installation_id" => installation_id,
          "webhook_delivery_id" => delivery.delivery_id,
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
          "comment" => {
            "id" => comment.fetch("id"),
            "url" => comment["html_url"],
            "created_at" => comment["created_at"],
            "updated_at" => comment["updated_at"]
          },
          "execution_created_at" => execution.created_at&.utc&.iso8601(6),
          "execution_finished_at" => execution.finished_at&.utc&.iso8601(6),
          "first_review_at" => first_review_at&.utc&.iso8601(6)
        }
      end

      def execution_for(number:)
        execution = RunDiffExecution
          .where(source: "github_pull_request")
          .where("context ->> 'repository' = ?", @repository)
          .where("context ->> 'pull_request_number' = ?", number.to_s)
          .order(created_at: :desc)
          .first

        execution || raise(Error, "no RunDiff execution found for #{@repository}##{number}")
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

      def validate_delivery!(delivery:, execution:, installation_id:)
        expected = {
          repository: @repository,
          pull_request_number: Integer(execution.context.fetch("pull_request_number")),
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

      def validate_current_head!(execution:, pull_request:)
        current_base = pull_request.dig("base", "sha")
        current_head = pull_request.dig("head", "sha")
        return if current_base == execution.baseline_sha && current_head == execution.candidate_sha

        raise Error,
          "PR head/base is stale for execution #{execution.execution_id}: " \
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

      def exact_comment(client:, number:)
        matches = client.comments(repository: @repository, number:).select do |comment|
          marker = comment.fetch("body", "").include?(CommentRenderer::MARKER)
          author = @bot_login.to_s.empty? || comment.dig("user", "login") == @bot_login
          marker && author
        end

        unless matches.one?
          raise Error, "expected one durable RunDiff comment on #{@repository}##{number}, found #{matches.length}"
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
