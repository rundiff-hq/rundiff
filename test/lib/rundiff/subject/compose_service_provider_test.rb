require "test_helper"
require "tmpdir"

class RunDiffSubjectComposeServiceProviderTest < ActiveSupport::TestCase
  class FakeRunner
    Call = Data.define(:env, :argv, :chdir)

    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(env:, argv:, chdir:)
      @calls << Call.new(env:, argv:, chdir: Pathname(chdir))

      result = if argv.include?("config")
        [ '{"services":{"redis":{"image":"redis:7-alpine"}}}', "", true ]
      elsif argv[0, 2] == [ "docker", "port" ]
        [ "127.0.0.1:49152\n", "", true ]
      elsif argv[0, 3] == [ "docker", "logs", "--tail" ]
        [ "redis ready\n", "", true ]
      elsif argv.include?("run")
        [ "container-123\n", "", true ]
      else
        [ "", "", true ]
      end

      RunDiff::Subject::ComposeServiceProvider::CommandResult.new(
        stdout: result.fetch(0),
        stderr: result.fetch(1),
        success: result.fetch(2)
      )
    end
  end

  test "runs one explicit image service on an ephemeral loopback port and tears it down" do
    Dir.mktmpdir("rundiff-compose-provider-") do |directory|
      root = Pathname(directory)
      root.join("compose.yml").write(<<~YAML)
        services:
          redis:
            image: redis:7-alpine
      YAML
      runner = FakeRunner.new
      provider = RunDiff::Subject::ComposeServiceProvider.new(
        command_runner: runner,
        host_env: {
          "PATH" => "/usr/bin",
          "HOME" => "/tmp/home",
          "SECRET_TOKEN" => "must-not-leak"
        }
      )

      started = provider.start(root:, role: "candidate", step: compose_start_step)

      assert_equal "127.0.0.1", started.host
      assert_equal 49_152, started.port
      assert_equal "container-123", started.handle.container_id
      assert_match(/\Arundiff-candidate-[a-f0-9]{12}\z/, started.handle.project_name)

      config_call = runner.calls.find { |call| call.argv.include?("config") }
      run_call = runner.calls.find { |call| call.argv.include?("run") }
      refute_nil config_call
      refute_nil run_call
      assert_equal({ "PATH" => "/usr/bin", "HOME" => "/tmp/home" }, run_call.env)
      refute run_call.env.key?("SECRET_TOKEN")
      assert_includes run_call.argv, "--no-deps"
      assert_includes run_call.argv, "--pull"
      assert_includes run_call.argv, "missing"
      assert_includes run_call.argv, "127.0.0.1::6379"
      refute_includes run_call.argv, "sh"
      refute_includes run_call.argv, "-c"

      assert_equal "redis ready\n", provider.diagnostics(started.handle)
      provider.stop(started.handle)

      assert runner.calls.any? { |call| call.argv[0, 3] == [ "docker", "rm", "-f" ] }
      assert runner.calls.any? { |call| call.argv.include?("down") && call.argv.include?("--volumes") }
    end
  end

  test "rejects privileged Compose features before executing the service" do
    Dir.mktmpdir("rundiff-compose-provider-") do |directory|
      root = Pathname(directory)
      root.join("compose.yml").write(<<~YAML)
        services:
          redis:
            image: redis:7-alpine
            volumes:
              - /var/run/docker.sock:/var/run/docker.sock
      YAML
      runner = FakeRunner.new
      provider = RunDiff::Subject::ComposeServiceProvider.new(command_runner: runner)

      error = assert_raises(RunDiff::Subject::ComposeServiceProvider::Error) do
        provider.start(root:, role: "candidate", step: compose_start_step)
      end

      assert_includes error.message, "unsupported keys: volumes"
      refute runner.calls.any? { |call| call.argv.include?("run") }
    end
  end

  test "rejects manifests that resolve outside the repository" do
    Dir.mktmpdir("rundiff-compose-provider-") do |directory|
      Dir.mktmpdir("rundiff-compose-outside-") do |outside|
        root = Pathname(directory)
        outside_manifest = Pathname(outside).join("compose.yml")
        outside_manifest.write("services:\n  redis:\n    image: redis:7-alpine\n")
        root.join("compose.yml").make_symlink(outside_manifest)
        provider = RunDiff::Subject::ComposeServiceProvider.new(command_runner: FakeRunner.new)

        error = assert_raises(RunDiff::Subject::ComposeServiceProvider::Error) do
          provider.start(root:, role: "candidate", step: compose_start_step)
        end

        assert_includes error.message, "manifest must resolve to a file inside the repository"
      end
    end
  end

  private

  def compose_start_step
    RunDiff::Subject::SetupPlan::Step.new(
      phase: "start_services",
      operation: "compose.run",
      provenance: "explicit",
      details: {
        name: "cache",
        manifest: "compose.yml",
        service: "redis",
        target_port: 6379,
        url_scheme: "redis",
        url_env: "REDIS_URL"
      }
    )
  end
end
