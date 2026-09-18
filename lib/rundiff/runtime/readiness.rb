require "uri"

module RunDiff
  module Runtime
    class Readiness
      Result = Data.define(:role, :errors) do
        def ready?
          errors.empty?
        end

        def to_h
          {
            "status" => ready? ? "ready" : "not_ready",
            "role" => role,
            "errors" => errors
          }
        end
      end

      EXECUTOR_FORBIDDEN_SECRETS = %w[
        RUNDIFF_GITHUB_PRIVATE_KEY_PATH
        RUNDIFF_GITHUB_WEBHOOK_SECRET
      ].freeze

      EXECUTOR_FORBIDDEN_REMOTE_CONFIG = %w[
        RUNDIFF_REMOTE_EXECUTOR_URL
        RUNDIFF_REMOTE_EXECUTOR_TOKEN
      ].freeze

      def initialize(
        env: ENV,
        rails_env: ::Rails.env,
        root: ::Rails.root,
        role: nil,
        database_check: -> { ApplicationRecord.connection.select_value("SELECT 1") }
      )
        @env = env
        @rails_env = rails_env.to_s
        @root = root
        @role = role || Role.from_env(env:, rails_env:)
        @database_check = database_check
      end

      def call
        errors = []
        validate_database!(errors)
        validate_production_role!(errors)

        if production?
          validate_control_plane!(errors) if @role.control_plane?
          validate_executor_service!(errors) if @role.executor_service?
        end

        Result.new(role: @role.name, errors: errors.freeze)
      end

      private

      def production?
        @rails_env == "production"
      end

      def validate_database!(errors)
        @database_check.call
      rescue StandardError => error
        errors << "Database connectivity failed (#{error.class})"
      end

      def validate_production_role!(errors)
        return unless production? && @role.combined?

        errors << "RUNDIFF_RUNTIME_ROLE=combined is not allowed for production readiness"
      end

      def validate_control_plane!(errors)
        require_https!(errors, "RUNDIFF_PUBLIC_URL")
        require_value!(errors, "RUNDIFF_GITHUB_APP_ID")
        require_value!(errors, "RUNDIFF_GITHUB_WEBHOOK_SECRET")
        require_readable_file!(errors, "RUNDIFF_GITHUB_PRIVATE_KEY_PATH")
        validate_repository_admission!(errors)

        unless @env["RUNDIFF_EXECUTOR"].to_s == "remote"
          errors << "RUNDIFF_EXECUTOR must be remote for a production control plane"
        end

        require_https!(errors, "RUNDIFF_REMOTE_EXECUTOR_URL")
        require_value!(errors, "RUNDIFF_REMOTE_EXECUTOR_TOKEN")
      end

      def validate_repository_admission!(errors)
        policy = RunDiff::Github::RepositoryAdmissionPolicy.new(env: @env, rails_env: @rails_env)

        unless policy.configured?
          errors << "RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST is required for a production control plane"
          return
        end

        if policy.wildcard?
          errors << "RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST must not contain * in production"
        end
      end

      def validate_executor_service!(errors)
        require_value!(errors, "RUNDIFF_EXECUTOR_SERVICE_TOKEN")

        unless @env["RUNDIFF_EXECUTOR_SERVICE_ADAPTER"].to_s == "git_clone"
          errors << "RUNDIFF_EXECUTOR_SERVICE_ADAPTER must be git_clone for production executor service"
        end

        EXECUTOR_FORBIDDEN_SECRETS.each do |name|
          errors << "#{name} must not be configured on the executor service" if configured?(name)
        end

        if @env["RUNDIFF_EXECUTOR"].to_s == "remote"
          errors << "RUNDIFF_EXECUTOR=remote must not be configured on the executor service"
        end

        EXECUTOR_FORBIDDEN_REMOTE_CONFIG.each do |name|
          errors << "#{name} must not be configured on the executor service" if configured?(name)
        end
      end

      def require_value!(errors, name)
        errors << "#{name} is required" unless configured?(name)
      end

      def require_https!(errors, name)
        value = @env[name].to_s
        unless https_url?(value)
          errors << "#{name} must be an absolute HTTPS URL"
        end
      end

      def require_readable_file!(errors, name)
        value = @env[name].to_s
        unless configured?(name)
          errors << "#{name} is required"
          return
        end

        path = File.expand_path(value, @root.to_s)
        errors << "#{name} must point to a readable file" unless File.file?(path) && File.readable?(path)
      end

      def configured?(name)
        !@env[name].to_s.empty?
      end

      def https_url?(value)
        uri = URI.parse(value)
        uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
