require "test_helper"
require "yaml"

class ProductionDeploymentContractTest < ActiveSupport::TestCase
  ROOT = Rails.root.join("deploy/production")

  test "production compose files use the canonical RunDiff GHCR repository" do
    %w[compose.control-plane.yml compose.executor.yml].each do |name|
      compose = ROOT.join(name).read

      assert_includes compose, "ghcr.io/rundiff-hq/rundiff:"
    end
  end

  test "control plane keeps application ports private and runs migrations plus Solid Queue worker" do
    compose = YAML.safe_load(ROOT.join("compose.control-plane.yml").read)
    services = compose.fetch("services")

    assert_equal [ "3000" ], services.dig("rundiff", "expose")
    assert_nil services.dig("rundiff", "ports")
    assert_includes services.dig("rundiff", "volumes"), "./.secrets:/run/secrets:ro"
    assert_equal "bin/rails db:prepare", services.dig("migrate", "command")
    assert_equal "bin/jobs", services.dig("worker", "command")
    assert_equal "service_completed_successfully", services.dig("rundiff", "depends_on", "migrate", "condition")
    assert_match(/RUNDIFF_CLOUDFLARED_IMAGE/, services.dig("tunnel", "image"))
  end

  test "executor keeps application and postgres ports private and prepares its ledger before start" do
    compose = YAML.safe_load(ROOT.join("compose.executor.yml").read)
    services = compose.fetch("services")

    assert_equal [ "3000" ], services.dig("rundiff", "expose")
    assert_nil services.dig("rundiff", "ports")
    assert_nil services.dig("postgres", "ports")
    assert_equal "bin/rails db:prepare", services.dig("migrate", "command")
    assert_equal "service_completed_successfully", services.dig("rundiff", "depends_on", "migrate", "condition")
    assert_match(/RUNDIFF_POSTGRES_IMAGE/, services.dig("postgres", "image"))
    assert_match(/RUNDIFF_CLOUDFLARED_IMAGE/, services.dig("tunnel", "image"))
  end

  test "executor environment example does not configure control-plane secrets or remote recursion" do
    env = ROOT.join("executor.env.example").read

    refute_match(/^RUNDIFF_GITHUB_PRIVATE_KEY_PATH=/, env)
    refute_match(/^RUNDIFF_GITHUB_WEBHOOK_SECRET=/, env)
    refute_match(/^RUNDIFF_REMOTE_EXECUTOR_URL=/, env)
    refute_match(/^RUNDIFF_REMOTE_EXECUTOR_TOKEN=/, env)
    refute_match(/^RUNDIFF_EXECUTOR=remote$/, env)

    assert_match(/^SECRET_KEY_BASE=$/, env)
    assert_match(/^RUNDIFF_RUNTIME_ROLE=executor_service$/, env)
    assert_match(/^RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone$/, env)
  end

  test "control-plane environment example requires remote execution, repository admission, and production app identity" do
    env = ROOT.join("control-plane.env.example").read

    assert_match(/^SECRET_KEY_BASE=$/, env)
    assert_match(/^RUNDIFF_RUNTIME_ROLE=control_plane$/, env)
    assert_match(/^RUNDIFF_GITHUB_APP_MANIFEST_ENV=production$/, env)
    assert_match(/^RUNDIFF_GITHUB_APP_SLUG=rundiff$/, env)
    assert_match(/^RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST=external-owner\/proof-repository$/, env)
    assert_match(/^RUNDIFF_ENABLE_GITHUB_APP_REGISTRATION=0$/, env)
    assert_match(/^RUNDIFF_EXECUTOR=remote$/, env)
    assert_match(%r{^RUNDIFF_REMOTE_EXECUTOR_URL=https://}, env)
  end
end
