module RunDiff
  module Github
    class AppDemoPreflight
      Error = Class.new(StandardError)

      Result = Data.define(
        :repository,
        :app_name,
        :app_slug,
        :installation_id,
        :regression_pr,
        :neutral_pr,
        :baseline_sha,
        :regression_sha,
        :neutral_sha,
        :executor_mode,
        :check_name
      )

      def initialize(
        authentication: nil,
        admission_policy: RepositoryAdmissionPolicy.new,
        pull_request_client_class: PullRequestClient,
        content_client_class: RepositoryContentClient,
        env: ENV,
        root: ::Rails.root
      )
        @authentication = authentication
        @admission_policy = admission_policy
        @pull_request_client_class = pull_request_client_class
        @content_client_class = content_client_class
        @env = env
        @root = root
      end

      def call(repository:, regression_pr:, neutral_pr:)
        repository = repository.to_s
        regression_pr = Integer(regression_pr)
        neutral_pr = Integer(neutral_pr)

        validate_repository!(repository)
        validate_executor_mode!

        app = authentication.app
        installation = authentication.repository_installation(repository:)
        installation_id = Integer(installation.fetch("id"))
        token = authentication.installation_token(
          installation_id:,
          repositories: [ repository.split("/", 2).last ],
          permissions: {
            contents: "read",
            pull_requests: "read"
          }
        )

        pull_requests = @pull_request_client_class.new(token: token.value)
        contents = @content_client_class.new(token: token.value)

        regression = pull_requests.fetch(repository:, number: regression_pr)
        neutral = pull_requests.fetch(repository:, number: neutral_pr)

        validate_pull_request!(
          repository:,
          number: regression_pr,
          pull_request: regression,
          label: "regression"
        )
        validate_pull_request!(
          repository:,
          number: neutral_pr,
          pull_request: neutral,
          label: "neutral"
        )

        baseline_sha = common_baseline!(regression:, neutral:)
        assert_candidate_only_config!(
          contents:,
          repository:,
          baseline_sha:,
          regression_sha: regression.dig("head", "sha"),
          neutral_sha: neutral.dig("head", "sha")
        )

        Result.new(
          repository:,
          app_name: app.fetch("name"),
          app_slug: app.fetch("slug"),
          installation_id:,
          regression_pr:,
          neutral_pr:,
          baseline_sha:,
          regression_sha: regression.dig("head", "sha"),
          neutral_sha: neutral.dig("head", "sha"),
          executor_mode: @env.fetch("RUNDIFF_EXECUTOR", "disabled"),
          check_name: @env.fetch("RUNDIFF_GITHUB_APP_CHECK_NAME", CheckRenderer::NAME)
        )
      rescue KeyError, ArgumentError, TypeError => error
        raise Error, "GitHub App demo preflight failed: #{error.message}"
      end

      private

      def authentication
        @authentication ||= AppAuthentication.from_env(root: @root)
      end

      def validate_repository!(repository)
        owner, name = repository.split("/", 2)
        if owner.to_s.empty? || name.to_s.empty? || name.include?("/")
          raise Error, "repository must use owner/name form"
        end

        unless @admission_policy.allowed?(repository)
          raise Error, "repository is not allowed by #{RepositoryAdmissionPolicy::ENV_NAME}: #{repository}"
        end
      end

      def validate_executor_mode!
        mode = @env.fetch("RUNDIFF_EXECUTOR", "disabled")
        return if mode == "remote"

        raise Error, "RUNDIFF_EXECUTOR must be remote for the installed-App demo, got #{mode.inspect}"
      end

      def validate_pull_request!(repository:, number:, pull_request:, label:)
        unless pull_request.fetch("state") == "open"
          raise Error, "#{label} PR #{repository}##{number} must be open"
        end

        base_repository = pull_request.dig("base", "repo", "full_name")
        head_repository = pull_request.dig("head", "repo", "full_name")
        unless base_repository == repository && head_repository == repository
          raise Error, "#{label} PR #{repository}##{number} must use branches in the same repository"
        end

        base_sha = pull_request.dig("base", "sha")
        head_sha = pull_request.dig("head", "sha")
        if base_sha.to_s.empty? || head_sha.to_s.empty? || base_sha == head_sha
          raise Error, "#{label} PR #{repository}##{number} must have distinct base/head SHAs"
        end
      end

      def common_baseline!(regression:, neutral:)
        regression_base = regression.dig("base", "sha")
        neutral_base = neutral.dig("base", "sha")
        return regression_base if regression_base == neutral_base

        raise Error,
          "demo PRs must share the same baseline: regression=#{regression_base.inspect} neutral=#{neutral_base.inspect}"
      end

      def assert_candidate_only_config!(contents:, repository:, baseline_sha:, regression_sha:, neutral_sha:)
        if contents.fetch(repository:, path: "rundiff.yml", ref: baseline_sha)
          raise Error, "baseline #{baseline_sha} must not contain rundiff.yml"
        end

        {
          "regression" => regression_sha,
          "neutral" => neutral_sha
        }.each do |label, sha|
          config = contents.fetch(repository:, path: "rundiff.yml", ref: sha)
          unless config.is_a?(Hash) && config["type"] == "file"
            raise Error, "#{label} candidate #{sha} must contain candidate-only rundiff.yml"
          end
        end
      end
    end
  end
end
