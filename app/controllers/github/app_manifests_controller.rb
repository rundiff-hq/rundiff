require "cgi"
require "securerandom"

module Github
  class AppManifestsController < ApplicationController
    before_action :ensure_registration_enabled!

    def new
      @manifest_environment = manifest_environment
      @manifest = RunDiff::Github::AppManifest.new(
        environment: @manifest_environment,
        public_url: ENV.fetch("RUNDIFF_PUBLIC_URL")
      ).to_h
      @state = SecureRandom.hex(32)
      session[:rundiff_github_app_manifest_state] = @state
      @registration_url = registration_url(@state)

      no_store!
    rescue KeyError, ArgumentError => error
      render plain: "GitHub App bootstrap configuration error: #{error.message}\n", status: :unprocessable_entity
    end

    def callback
      unless valid_state?
        return render plain: "GitHub App manifest state mismatch. Start the registration flow again.\n",
          status: :unprocessable_entity
      end

      @credentials = RunDiff::Github::AppManifestConverter.new.call(code: params.require(:code))
      @manifest_environment = manifest_environment
      @private_key_path = "tmp/github-app/rundiff-#{@manifest_environment}.pem"
      @install_url = "https://github.com/apps/#{@credentials.fetch("slug")}/installations/new"

      persist_development_credentials!
      no_store!
    rescue ActionController::ParameterMissing, KeyError, RunDiff::Github::AppManifestConverter::Error => error
      render plain: "GitHub App manifest conversion failed: #{error.message}\n", status: :bad_gateway
    end

    private

    def manifest_environment
      ENV.fetch("RUNDIFF_GITHUB_APP_MANIFEST_ENV", Rails.env.production? ? "production" : "development")
    end

    def registration_url(state)
      owner = ENV.fetch("RUNDIFF_GITHUB_APP_OWNER", "rundiff-hq")
      encoded_owner = CGI.escapeURIComponent(owner)
      encoded_state = CGI.escapeURIComponent(state)
      "https://github.com/organizations/#{encoded_owner}/settings/apps/new?state=#{encoded_state}"
    end

    def valid_state?
      expected = session.delete(:rundiff_github_app_manifest_state).to_s
      actual = params[:state].to_s
      return false if expected.empty? || actual.empty? || expected.bytesize != actual.bytesize

      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end

    def persist_development_credentials!
      return unless Rails.env.development? && @manifest_environment == "development"

      store = RunDiff::Github::DevelopmentCredentialStore.new.write!(@credentials)
      @private_key_path = store.private_key_path.relative_path_from(Rails.root).to_s
      @credential_env_path = store.env_path.relative_path_from(Rails.root).to_s
    end

    def ensure_registration_enabled!
      return if Rails.env.development? || Rails.env.test?
      return if ENV["RUNDIFF_ENABLE_GITHUB_APP_REGISTRATION"] == "1"

      head :not_found
    end

    def no_store!
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end
  end
end
