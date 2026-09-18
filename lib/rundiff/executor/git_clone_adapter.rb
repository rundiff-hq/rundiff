require "base64"
require "fileutils"
require "tmpdir"
require "uri"

module RunDiff
  module Executor
    class GitCloneAdapter
      Error = Class.new(StandardError)
      REPOSITORY_PATTERN = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}.freeze

      def initialize(
        root: ::Rails.root,
        workspace_root: nil,
        command_runner: RunDiff::Github::LocalPullRequestRunner::CommandRunner.new,
        runner_factory: nil,
        repository_capability_provider: nil,
        git_base_url: ENV.fetch("RUNDIFF_GITHUB_GIT_BASE_URL", "https://github.com"),
        stage_timer: RunDiff::ExecutionStageTimer.new
      )
        @root = Pathname(root).expand_path
        @workspace_root = Pathname(workspace_root || File.join(Dir.tmpdir, "rundiff", "repositories")).expand_path
        assert_workspace_root_isolated!
        @command_runner = command_runner
        @repository_capability_provider = repository_capability_provider
        @git_base_url = normalize_git_base_url(git_base_url)
        @stage_timer = stage_timer
        @runner_factory = runner_factory || lambda do |repository_root:|
          default_runner(repository_root:)
        end
      end

      def call(request:, repository_capability: nil)
        repository_capability ||= @repository_capability_provider&.call(request:)
        raise Error, "Repository capability is required for git clone execution" unless repository_capability

        context = request.context
        repository = context.fetch("repository")
        candidate_repository = context.fetch("candidate_repository")
        unless repository == candidate_repository
          raise Error, "Git clone executor currently supports same-repository pull requests only"
        end
        raise Error, "Executor repository must use owner/name form" unless REPOSITORY_PATTERN.match?(repository)

        repository_root = repository_root(request:)
        @stage_timer.measure(execution_id: request.execution_id, stage: "repository_prepare") do
          prepare_repository!(
            repository_root:,
            repository:,
            pull_request_number: Integer(context.fetch("pull_request_number")),
            baseline_ref: context.fetch("baseline_ref"),
            repository_capability:
          )
          assert_commit!(repository_root:, sha: request.baseline_sha)
          assert_commit!(repository_root:, sha: request.candidate_sha)
        end

        runner = @runner_factory.call(repository_root:)
        payload = @stage_timer.measure(execution_id: request.execution_id, stage: "behavioral_diff") do
          runner.call(execution: request)
        end
        Result.success(payload)
      rescue StandardError => error
        Result.failure(error)
      ensure
        FileUtils.rm_rf(repository_root) if repository_root
      end

      private

      def default_runner(repository_root:)
        execution_identity = RunDiff::Subject::ExecutionIdentity.from_env
        runtime_capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
        compose_provider = RunDiff::Subject::IsolatedComposeProviderClient.from_env

        if compose_provider
          runtime_capabilities = runtime_capabilities.with_service_provider(
            "compose",
            compose_provider.provider_version
          )
        elsif runtime_capabilities.service_provider?("compose")
          raise Error,
            "Executor declares Compose capability without a reachable isolated Compose provider"
        end

        RunDiff::Github::LocalPullRequestRunner.new(
          root: repository_root,
          tool_root: @root,
          fetch_repository: false,
          command_runner: @command_runner,
          execution_identity:,
          runtime_capabilities:,
          service_executor: RunDiff::Subject::ServiceExecutor.new(
            execution_identity:,
            compose_provider:
          )
        )
      end

      def prepare_repository!(repository_root:, repository:, pull_request_number:, baseline_ref:, repository_capability:)
        FileUtils.rm_rf(repository_root)
        FileUtils.mkdir_p(repository_root.dirname)

        run!(command: [ "git", "init", repository_root.to_s ], chdir: @root)
        run!(
          command: [ "git", "remote", "add", "origin", repository_url(repository) ],
          chdir: repository_root
        )
        run!(
          env: git_auth_environment(repository_capability:),
          command: [
            "git", "fetch", "--no-tags", "origin",
            "+refs/heads/#{baseline_ref}:refs/remotes/origin/rundiff-base",
            "+refs/pull/#{pull_request_number}/head:refs/remotes/origin/rundiff-candidate"
          ],
          chdir: repository_root
        )
      end

      def assert_commit!(repository_root:, sha:)
        run!(command: [ "git", "cat-file", "-e", "#{sha}^{commit}" ], chdir: repository_root)
      end

      def git_auth_environment(repository_capability:)
        basic = Base64.strict_encode64("x-access-token:#{repository_capability.token}")
        {
          "GIT_TERMINAL_PROMPT" => "0",
          "GIT_CONFIG_COUNT" => "1",
          "GIT_CONFIG_KEY_0" => "http.#{@git_base_url}/.extraheader",
          "GIT_CONFIG_VALUE_0" => "AUTHORIZATION: basic #{basic}"
        }
      end

      def repository_url(repository)
        "#{@git_base_url}/#{repository}.git"
      end

      def normalize_git_base_url(value)
        uri = URI.parse(value.to_s.sub(%r{/+$}, ""))
        unless %w[http https].include?(uri.scheme) && uri.host.present?
          raise Error, "Git base URL must be an absolute HTTP(S) URL"
        end

        uri.to_s.sub(%r{/+$}, "")
      rescue URI::InvalidURIError
        raise Error, "Git base URL must be an absolute HTTP(S) URL"
      end

      def repository_root(request:)
        suffix = request.execution_id.delete_prefix("github-")[0, 16]
        @workspace_root.join(suffix)
      end

      def assert_workspace_root_isolated!
        rails_ancestor = @workspace_root.ascend.find { |path| path.join("config.ru").file? }
        return unless rails_ancestor

        raise Error,
          "Executor workspace root #{@workspace_root} is nested under Rails application #{rails_ancestor}; " \
          "choose an isolated workspace root"
      end

      def run!(command:, chdir:, env: {})
        @command_runner.call(env:, command:, chdir: chdir.to_s)
      end
    end
  end
end
