require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class ProductionOperatorWorkflowTest < ActiveSupport::TestCase
  ROOT = Rails.root
  PRODUCTION = ROOT.join("deploy/production")

  test "initializes control-plane files without overwriting existing values" do
    Dir.mktmpdir("rundiff-production-init-") do |destination|
      stdout, stderr, status = run_script("init-production-role", "control-plane", destination)

      assert status.success?, stderr
      assert_includes stdout, "Initialized control-plane production files"
      assert File.file?(File.join(destination, ".env"))
      assert File.file?(File.join(destination, ".env.control-plane"))
      assert File.file?(File.join(destination, ".env.control-plane.tunnel"))
      assert_equal 0o700, File.stat(File.join(destination, ".secrets")).mode & 0o777

      control_plane_env = File.join(destination, ".env.control-plane")
      File.write(control_plane_env, "SENTINEL=keep-me\n")

      _stdout, stderr, status = run_script("init-production-role", "control-plane", destination)

      assert status.success?, stderr
      assert_equal "SENTINEL=keep-me\n", File.read(control_plane_env)
    end
  end

  test "initializes executor files" do
    Dir.mktmpdir("rundiff-production-init-") do |destination|
      _stdout, stderr, status = run_script("init-production-role", "executor", destination)

      assert status.success?, stderr
      assert File.file?(File.join(destination, ".env"))
      assert File.file?(File.join(destination, ".env.executor"))
      assert File.file?(File.join(destination, ".env.executor.postgres"))
      assert File.file?(File.join(destination, ".env.executor.tunnel"))
    end
  end

  test "deploy action validates, pulls, starts, and shows status for the selected role" do
    Dir.mktmpdir("rundiff-production-deploy-") do |destination|
      prepare_control_plane_deploy_dir(destination)
      fake_bin = File.join(destination, "fake-bin")
      log = File.join(destination, "docker.log")
      FileUtils.mkdir_p(fake_bin)
      write_executable(
        File.join(fake_bin, "docker"),
        <<~BASH
          #!/usr/bin/env bash
          printf '%s\\n' "$*" >> "$DOCKER_LOG"
          exit 0
        BASH
      )

      env = {
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
        "DOCKER_LOG" => log,
        "RUNDIFF_PRODUCTION_DEPLOY_DIR" => destination
      }

      _stdout, stderr, status = run_script("deploy-production-role", "control-plane", "deploy", env:)

      assert status.success?, stderr
      calls = File.readlines(log, chomp: true)
      assert_equal "compose version", calls.fetch(0)
      assert_includes calls, compose_call(destination, "config --quiet")
      assert_includes calls, compose_call(destination, "pull")
      assert_includes calls, compose_call(destination, "up -d --remove-orphans")
      assert_includes calls, compose_call(destination, "ps")
    end
  end

  test "deploy action fails before Docker when a required env file is absent" do
    Dir.mktmpdir("rundiff-production-deploy-") do |destination|
      FileUtils.cp(PRODUCTION.join("compose.executor.yml"), File.join(destination, "compose.executor.yml"))
      File.write(File.join(destination, ".env"), "RUNDIFF_IMAGE_TAG=sha-test\n")

      _stdout, stderr, status = run_script(
        "deploy-production-role",
        "executor",
        "deploy",
        env: { "RUNDIFF_PRODUCTION_DEPLOY_DIR" => destination }
      )

      refute status.success?
      assert_includes stderr, "missing required deployment file"
      assert_includes stderr, ".env.executor"
    end
  end

  test "release helper dispatches on a Git ref but pins checkout to an exact commit sha" do
    Dir.mktmpdir("rundiff-production-release-") do |destination|
      fake_bin = File.join(destination, "fake-bin")
      log = File.join(destination, "gh.log")
      sha = "a" * 40
      FileUtils.mkdir_p(fake_bin)
      write_executable(
        File.join(fake_bin, "gh"),
        <<~BASH
          #!/usr/bin/env bash
          printf '%s\\n' "$*" >> "$GH_LOG"
          if [[ "$1" == "api" ]]; then
            echo "$RELEASE_SHA"
          fi
        BASH
      )

      stdout, stderr, status = run_script(
        "release-production-image",
        "main",
        env: {
          "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
          "GH_LOG" => log,
          "RELEASE_SHA" => sha
        }
      )

      assert status.success?, stderr
      calls = File.readlines(log, chomp: true)
      assert_includes calls, "api repos/rundiff-hq/rundiff/commits/main --jq .sha"
      assert_includes calls,
        "workflow run release-image.yml --repo rundiff-hq/rundiff --ref main -f release_sha=#{sha}"
      assert_includes stdout, "image tag:  sha-#{sha}"
    end
  end

  test "production identity verifier checks canonical public surfaces" do
    Dir.mktmpdir("rundiff-production-identity-") do |destination|
      fake_bin = File.join(destination, "fake-bin")
      FileUtils.mkdir_p(fake_bin)
      write_executable(
        File.join(fake_bin, "curl"),
        <<~BASH
          #!/usr/bin/env bash
          url="${!#}"
          case "$url" in
            https://app.rundiff.com/up)
              exit 0
              ;;
            https://app.rundiff.com/ready)
              printf '%s\\n' '{"status":"ready","role":"control_plane","errors":[]}'
              ;;
            https://executor.rundiff.com/up)
              exit 0
              ;;
            https://executor.rundiff.com/ready)
              printf '%s\\n' '{"status":"ready","role":"executor_service","errors":[]}'
              ;;
            https://app.rundiff.com/onboarding)
              printf '%s\\n' '<html><title>RunDiff</title><body>RunDiff onboarding Tests passed. Behavior changed. RunDiff / Behavioral Review</body></html>'
              ;;
            https://github.com/apps/rundiff)
              printf '%s\\n' '<html><title>RunDiff</title><body>RunDiff</body></html>'
              ;;
            *)
              echo "unexpected URL: $url" >&2
              exit 22
              ;;
          esac
        BASH
      )

      stdout, stderr, status = run_script(
        "verify-production-identity",
        env: {
          "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
          "RUNDIFF_GITHUB_APP_SLUG" => "rundiff",
          "RUNDIFF_SKIP_AUTHENTICATED_APP_CHECK" => "1"
        }
      )

      assert status.success?, stderr
      assert_includes stdout, "production_identity=verified"
      assert_includes stdout, "control_plane=https://app.rundiff.com"
      assert_includes stdout, "executor=https://executor.rundiff.com"
      assert_includes stdout, "github_app_slug=rundiff"
    end
  end

  test "production cutover verifier runs identity then Cloudflare and may stop before proof" do
    Dir.mktmpdir("rundiff-production-cutover-") do |destination|
      infra = File.join(destination, "infra")
      FileUtils.mkdir_p(File.join(infra, "scripts"))
      log = File.join(destination, "cutover.log")
      identity = File.join(destination, "identity")
      cloudflare = File.join(infra, "scripts", "verify_cloudflare_identity.py")

      write_executable(identity, <<~BASH)
        #!/usr/bin/env bash
        printf '%s\\n' identity >> "$CUTOVER_LOG"
        printf '%s\\n' production_identity=verified
      BASH
      write_executable(cloudflare, <<~PYTHON)
        #!/usr/bin/env python3
        import os
        with open(os.environ["CUTOVER_LOG"], "a", encoding="utf-8") as handle:
            handle.write("cloudflare\\n")
        print("cloudflare_identity=verified")
      PYTHON

      stdout, stderr, status = run_script(
        "verify-production-cutover",
        "--infra-repo",
        infra,
        env: {
          "RUNDIFF_IDENTITY_VERIFIER" => identity,
          "CUTOVER_LOG" => log
        }
      )

      assert status.success?, stderr
      assert_equal %w[identity cloudflare], File.readlines(log, chomp: true)
      assert_includes stdout, "stage=production_identity status=verified"
      assert_includes stdout, "stage=cloudflare_identity status=verified"
      assert_includes stdout, "stage=production_proof status=not_requested"
      assert_includes stdout, "production_cutover=verified"
    end
  end

  test "production cutover verifier collects proof only when all proof arguments are present" do
    Dir.mktmpdir("rundiff-production-cutover-") do |destination|
      infra = File.join(destination, "infra")
      FileUtils.mkdir_p(File.join(infra, "scripts"))
      log = File.join(destination, "cutover.log")
      identity = File.join(destination, "identity")
      proof = File.join(destination, "proof")
      cloudflare = File.join(infra, "scripts", "verify_cloudflare_identity.py")
      output = File.join(destination, "proof.json")

      write_executable(identity, <<~BASH)
        #!/usr/bin/env bash
        printf '%s\\n' identity >> "$CUTOVER_LOG"
      BASH
      write_executable(cloudflare, <<~PYTHON)
        #!/usr/bin/env python3
        import os
        with open(os.environ["CUTOVER_LOG"], "a", encoding="utf-8") as handle:
            handle.write("cloudflare\\n")
      PYTHON
      write_executable(proof, <<~BASH)
        #!/usr/bin/env bash
        printf 'proof %s\\n' "$*" >> "$CUTOVER_LOG"
        printf '%s\\n' '{"schema_version":"1"}' > "$7"
      BASH

      stdout, stderr, status = run_script(
        "verify-production-cutover",
        "--infra-repo",
        infra,
        "--proof-repo",
        "external-owner/proof-repo",
        "--regression-pr",
        "12",
        "--neutral-pr",
        "13",
        "--proof-output",
        output,
        env: {
          "RUNDIFF_IDENTITY_VERIFIER" => identity,
          "RUNDIFF_PROOF_COLLECTOR" => proof,
          "CUTOVER_LOG" => log
        }
      )

      assert status.success?, stderr
      calls = File.readlines(log, chomp: true)
      assert_equal "identity", calls.fetch(0)
      assert_equal "cloudflare", calls.fetch(1)
      assert_includes calls.fetch(2), "proof external-owner/proof-repo --regression-pr 12 --neutral-pr 13 --output #{output}"
      assert File.file?(output)
      assert_includes stdout, "stage=production_proof status=verified output=#{output}"
      assert_includes stdout, "production_cutover=verified"
    end
  end

  test "production cutover verifier rejects partial proof arguments before running stages" do
    Dir.mktmpdir("rundiff-production-cutover-") do |destination|
      infra = File.join(destination, "infra")
      FileUtils.mkdir_p(File.join(infra, "scripts"))
      File.write(File.join(infra, "scripts", "verify_cloudflare_identity.py"), "")

      _stdout, stderr, status = run_script(
        "verify-production-cutover",
        "--infra-repo",
        infra,
        "--proof-repo",
        "external-owner/proof-repo"
      )

      refute status.success?
      assert_includes stderr, "proof mode requires"
    end
  end

  test "production cutover verifier fails when the infra verifier is missing" do
    Dir.mktmpdir("rundiff-production-cutover-") do |destination|
      _stdout, stderr, status = run_script(
        "verify-production-cutover",
        "--infra-repo",
        destination
      )

      refute status.success?
      assert_includes stderr, "Cloudflare verifier not found"
    end
  end

  test "release workflow publishes the exact head only after successful main CI" do
    workflow = ROOT.join(".github/workflows/release-image.yml").read

    assert_includes workflow, "workflow_run:"
    assert_includes workflow, "      - CI"
    assert_includes workflow, "      - main"
    assert_includes workflow, "github.event.workflow_run.conclusion == 'success'"
    assert_includes workflow, "github.event.workflow_run.head_sha"
    assert_includes workflow, "ref: ${{ env.RELEASE_SHA }}"
    assert_includes workflow, "type=raw,value=sha-${{ steps.release.outputs.sha }}"
  end

  private

  def run_script(name, *args, env: {})
    Open3.capture3(env, "bash", ROOT.join("bin", name).to_s, *args)
  end

  def prepare_control_plane_deploy_dir(destination)
    FileUtils.cp(PRODUCTION.join("compose.control-plane.yml"), File.join(destination, "compose.control-plane.yml"))
    File.write(File.join(destination, ".env"), "RUNDIFF_IMAGE_TAG=sha-test\nRUNDIFF_CLOUDFLARED_IMAGE=cloudflared@test\n")
    File.write(File.join(destination, ".env.control-plane"), "RAILS_ENV=production\n")
    File.write(File.join(destination, ".env.control-plane.tunnel"), "TUNNEL_TOKEN=test\n")
  end

  def compose_call(destination, suffix)
    "compose --project-directory #{destination} --env-file #{destination}/.env " \
      "-f #{destination}/compose.control-plane.yml #{suffix}"
  end

  def write_executable(path, content)
    File.write(path, content)
    FileUtils.chmod(0o755, path)
  end
end
