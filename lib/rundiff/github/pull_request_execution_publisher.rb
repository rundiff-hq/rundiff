module RunDiff
  module Github
    class PullRequestExecutionPublisher
      DEFAULT_CHECK_NAME = "RunDiff / Behavioral Review".freeze
      DEFAULT_BOT_LOGIN = "rundiff-checks[bot]".freeze

      def initialize(
        token:,
        api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com"),
        check_name: ENV.fetch("RUNDIFF_GITHUB_APP_CHECK_NAME", DEFAULT_CHECK_NAME),
        bot_login: ENV.fetch("RUNDIFF_GITHUB_APP_BOT_LOGIN", DEFAULT_BOT_LOGIN)
      )
        @token = token
        @api_url = api_url
        @check_name = check_name
        @bot_login = bot_login
      end

      def call(execution:, payload:)
        context = execution.context
        repository = context.fetch("repository")
        pr_number = Integer(context.fetch("pull_request_number"))
        run_url = "https://github.com/#{repository}/pull/#{pr_number}"
        rendered = CheckRenderer.call(payload:, run_url:)

        check_action = check_publisher.upsert(
          repository:,
          head_sha: execution.candidate_sha,
          name: @check_name,
          external_id: execution.execution_id,
          details_url: run_url,
          conclusion: rendered.fetch("conclusion"),
          title: rendered.fetch("title"),
          summary: rendered.fetch("summary"),
          annotations: rendered.fetch("annotations")
        )

        markdown = CommentRenderer.markdown(
          payload:,
          context: comment_context(execution:, repository:, pr_number:, run_url:)
        )

        comment_action = comment_publisher.upsert(
          repository:,
          pr_number:,
          body: markdown,
          author: @bot_login,
          expected_head_sha: execution.candidate_sha
        )

        { check: check_action, comment: comment_action }
      end

      def infra_failure(execution:, error: nil, error_class: nil, error_message: nil)
        failure_class = error_class || error&.class&.to_s || "UnknownError"
        failure_detail = public_failure_detail(failure_class:, error_message: error_message || error&.message)
        context = execution.context
        repository = context.fetch("repository")
        pr_number = Integer(context.fetch("pull_request_number"))
        run_url = "https://github.com/#{repository}/pull/#{pr_number}"
        summary = <<~MARKDOWN.strip
          **INFRA_FAILURE** - RunDiff could not complete this validation.

          This is an execution infrastructure failure, **not a product regression**. It is safe to re-run the check after the infrastructure issue is resolved.

          Execution: `#{execution.execution_id}`<br>
          Failure class: `#{failure_class}`
          #{failure_detail ? "Failure detail: `#{failure_detail}`" : nil}
        MARKDOWN

        check_action = check_publisher.upsert(
          repository:,
          head_sha: execution.candidate_sha,
          name: @check_name,
          external_id: execution.execution_id,
          details_url: run_url,
          conclusion: "failure",
          title: "RunDiff could not complete validation",
          summary:,
          annotations: []
        )

        markdown = <<~MARKDOWN
          <!-- rundiff:behavioral-diff:v1 -->
          ## 🟣 RunDiff Execution Problem

          > [!WARNING]
          > **RunDiff could not complete validation.** This is an **INFRA_FAILURE**, not a product regression.

          The check can be re-run after the execution infrastructure is healthy.

          Run: `#{execution.execution_id}`<br>
          Candidate: `#{execution.candidate_sha.first(8)}`<br>
          Failure class: `#{failure_class}`
          #{failure_detail ? "Failure detail: `#{failure_detail}`" : nil}
        MARKDOWN

        comment_action = comment_publisher.upsert(
          repository:,
          pr_number:,
          body: markdown,
          author: @bot_login,
          expected_head_sha: execution.candidate_sha
        )

        { check: check_action, comment: comment_action }
      end

      private

      def public_failure_detail(failure_class:, error_message:)
        return unless failure_class == "RunDiff::Executor::HttpAdapter::Error"

        error_message.to_s.lines.first.to_s.tr("`", "'").strip.truncate(300).presence
      end

      def check_publisher
        CheckPublisher.new(token: @token, api_url: @api_url)
      end

      def comment_publisher
        CommentPublisher.new(token: @token, api_url: @api_url)
      end

      def comment_context(execution:, repository:, pr_number:, run_url:)
        {
          repository:,
          pr_number:,
          baseline_label: execution.context.fetch("baseline_ref"),
          baseline_sha: execution.baseline_sha,
          candidate_label: execution.context.fetch("candidate_ref"),
          candidate_sha: execution.candidate_sha,
          bootstrap_baseline: nil,
          execution_mode: "RunDiff GitHub App - exact Git worktrees + isolated subject state",
          run_url:
        }
      end
    end
  end
end
