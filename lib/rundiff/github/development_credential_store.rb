require "fileutils"
require "shellwords"

module RunDiff
  module Github
    class DevelopmentCredentialStore
      attr_reader :private_key_path, :env_path

      def initialize(root: ::Rails.root)
        @root = root
        @directory = @root.join("tmp/github-app")
        @private_key_path = @directory.join("rundiff-development.pem")
        @env_path = @directory.join("development.env")
      end

      def write!(credentials)
        FileUtils.mkdir_p(@directory)

        @private_key_path.write(credentials.fetch("pem"))
        File.chmod(0o600, @private_key_path)

        values = {
          "RUNDIFF_GITHUB_APP_ID" => credentials.fetch("id").to_s,
          "RUNDIFF_GITHUB_CLIENT_ID" => credentials.fetch("client_id"),
          "RUNDIFF_GITHUB_WEBHOOK_SECRET" => credentials.fetch("webhook_secret"),
          "RUNDIFF_GITHUB_PRIVATE_KEY_PATH" => @private_key_path.relative_path_from(@root).to_s
        }

        @env_path.write(
          values.map { |key, value| "export #{key}=#{Shellwords.escape(value)}" }.join("\n") + "\n"
        )
        File.chmod(0o600, @env_path)

        values.each { |key, value| ENV[key] = value }
        self
      end
    end
  end
end
