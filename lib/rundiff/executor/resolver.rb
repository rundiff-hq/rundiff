module RunDiff
  module Executor
    class Resolver
      Error = Class.new(StandardError)

      def self.from_env(root: ::Rails.root, env: ENV, rails_env: ::Rails.env)
        mode = env["RUNDIFF_EXECUTOR"] || env["RUNDIFF_GITHUB_EXECUTION_MODE"]
        mode ||= rails_env.development? ? "git_clone" : "disabled"

        case mode
        when "local"
          LocalAdapter.new(root:)
        when "git_clone"
          authenticated_git_clone_adapter(root:)
        when "remote"
          remote_adapter(root:, env:)
        when "disabled"
          raise Error, "RunDiff executor is disabled"
        else
          raise Error, "Unsupported RUNDIFF_EXECUTOR=#{mode.inspect}"
        end
      end

      def self.authenticated_git_clone_adapter(root:)
        GitCloneAdapter.new(
          root:,
          repository_capability_provider: RunDiff::Github::RepositoryCapabilityProvider.new(root:)
        )
      end
      private_class_method :authenticated_git_clone_adapter

      def self.remote_adapter(root:, env:)
        url = env["RUNDIFF_REMOTE_EXECUTOR_URL"].to_s
        token = env["RUNDIFF_REMOTE_EXECUTOR_TOKEN"].to_s
        raise Error, "RUNDIFF_REMOTE_EXECUTOR_URL is required" if url.empty?
        raise Error, "RUNDIFF_REMOTE_EXECUTOR_TOKEN is required" if token.empty?

        HttpAdapter.new(
          url:,
          token:,
          open_timeout: env.fetch(
            "RUNDIFF_REMOTE_EXECUTOR_OPEN_TIMEOUT_SECONDS",
            HttpAdapter::DEFAULT_OPEN_TIMEOUT_SECONDS
          ),
          read_timeout: env.fetch(
            "RUNDIFF_REMOTE_EXECUTOR_READ_TIMEOUT_SECONDS",
            HttpAdapter::DEFAULT_READ_TIMEOUT_SECONDS
          ),
          retry_attempts: env.fetch(
            "RUNDIFF_REMOTE_EXECUTOR_RETRY_ATTEMPTS",
            HttpAdapter::DEFAULT_RETRY_ATTEMPTS
          ),
          retry_base_delay: env.fetch(
            "RUNDIFF_REMOTE_EXECUTOR_RETRY_BASE_DELAY_SECONDS",
            HttpAdapter::DEFAULT_RETRY_BASE_DELAY_SECONDS
          ),
          repository_capability_provider: RunDiff::Github::RepositoryCapabilityProvider.new(root:)
        )
      rescue HttpAdapter::Error, ArgumentError => error
        raise Error, error.message
      end
      private_class_method :remote_adapter
    end
  end
end
