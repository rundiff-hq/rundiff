class OnboardingController < ApplicationController
  GITHUB_APP_SLUGS = {
    "development" => "rundiff-development",
    "staging" => "rundiff-staging",
    "production" => "rundiff"
  }.freeze

  CONFIGURATION = <<~YAML.freeze
    version: 1
    scenario:
      path: /orders/42
    subject:
      persistence: auto
  YAML

  def index
    @github_app_slug = ENV.fetch("RUNDIFF_GITHUB_APP_SLUG") { default_github_app_slug }
    unless /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/.match?(@github_app_slug)
      return render plain: "RunDiff GitHub App configuration error: invalid RUNDIFF_GITHUB_APP_SLUG\n",
        status: :unprocessable_entity
    end

    @install_url = "https://github.com/apps/#{@github_app_slug}/installations/new"
    @post_install_return = post_install_return?
    @configuration = CONFIGURATION
  end

  private

  def post_install_return?
    params.key?(:installation_id) || %w[install update].include?(params[:setup_action])
  end

  def default_github_app_slug
    environment = ENV.fetch(
      "RUNDIFF_GITHUB_APP_MANIFEST_ENV",
      Rails.env.production? ? "production" : "development"
    )

    GITHUB_APP_SLUGS.fetch(environment) do
      raise ArgumentError, "unsupported GitHub App environment: #{environment.inspect}"
    end
  end
end
