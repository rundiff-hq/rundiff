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
