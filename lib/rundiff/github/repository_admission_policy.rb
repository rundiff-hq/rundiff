module RunDiff
  module Github
    class RepositoryAdmissionPolicy
      ENV_NAME = "RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST"

      def initialize(env: ENV, rails_env: ::Rails.env)
        @env = env
        @rails_env = rails_env.to_s
      end

      def allowed?(repository)
        entries = allowlist
        return true if entries.empty? && !production?
        return false if repository.to_s.empty?

        entries.include?(repository.to_s)
      end

      def configured?
        !allowlist.empty?
      end

      def wildcard?
        allowlist.include?("*")
      end

      def allowlist
        @allowlist ||= @env[ENV_NAME].to_s.split(",").map(&:strip).reject(&:empty?).uniq.freeze
      end

      private

      def production?
        @rails_env == "production"
      end
    end
  end
end
