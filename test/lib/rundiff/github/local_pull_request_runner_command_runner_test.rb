require "test_helper"
require "json"
require "rbconfig"

class RunDiffGithubLocalPullRequestRunnerCommandRunnerTest < ActiveSupport::TestCase
  class WorkspaceIdentity
    attr_reader :prepared_workspace

    def prepare_runtime_home(workspace)
      @prepared_workspace = workspace.to_s
    end

    def environment(workspace:)
      {
        "HOME" => File.join(workspace.to_s, "tmp", "rundiff", "home"),
        "USER" => "rundiff-subject",
        "LOGNAME" => "rundiff-subject"
      }
    end

    def spawn_options
      {}
    end
  end

  test "inherits only safe host variables and explicit command environment" do
    host_env = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => ENV.fetch("HOME", "/tmp"),
      "TMPDIR" => ENV.fetch("TMPDIR", "/tmp"),
      "LANG" => "en_US.UTF-8",
      "RUBYOPT" => "-rbootsnap/setup",
      "RUBYLIB" => "/private/rundiff/ruby",
      "RUNDIFF_EXECUTOR_SERVICE_TOKEN" => "executor-secret",
      "RUNDIFF_GITHUB_WEBHOOK_SECRET" => "webhook-secret",
      "SSH_AUTH_SOCK" => "/private/ssh-agent.sock"
    }
    runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new(host_env:)
    keys = host_env.keys + [ "RUNDIFF_EXPLICIT_SENTINEL" ]
    script = "require 'json'; print JSON.generate(ENV.to_h.slice(*#{keys.inspect}))"

    output = runner.call(
      env: { "RUNDIFF_EXPLICIT_SENTINEL" => "visible" },
      command: [ RbConfig.ruby, "-e", script ],
      chdir: Rails.root.to_s
    )
    child_env = JSON.parse(output)

    assert_equal host_env.fetch("PATH"), child_env.fetch("PATH")
    assert_equal host_env.fetch("HOME"), child_env.fetch("HOME")
    assert_equal host_env.fetch("TMPDIR"), child_env.fetch("TMPDIR")
    assert_equal host_env.fetch("LANG"), child_env.fetch("LANG")
    assert_equal "visible", child_env.fetch("RUNDIFF_EXPLICIT_SENTINEL")
    refute child_env.key?("RUBYOPT")
    refute child_env.key?("RUBYLIB")
    refute child_env.key?("RUNDIFF_EXECUTOR_SERVICE_TOKEN")
    refute child_env.key?("RUNDIFF_GITHUB_WEBHOOK_SECRET")
    refute child_env.key?("SSH_AUTH_SOCK")
  end

  test "caller can explicitly unset an inherited safe variable" do
    runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new(
      host_env: { "PATH" => ENV.fetch("PATH"), "HOME" => "/private/host-home" }
    )

    output = runner.call(
      env: { "HOME" => nil },
      command: [ RbConfig.ruby, "-e", "print ENV.key?('HOME')" ],
      chdir: Rails.root.to_s
    )

    assert_equal "false", output
  end

  test "subject identity environment overrides caller and host identity values" do
    identity = WorkspaceIdentity.new
    runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new(
      host_env: {
        "PATH" => ENV.fetch("PATH"),
        "HOME" => "/root"
      },
      execution_identity: identity
    )

    output = runner.call(
      env: {
        "HOME" => "/attacker-home",
        "USER" => "root",
        "LOGNAME" => "root"
      },
      command: [
        RbConfig.ruby,
        "-e",
        "print [ENV['HOME'], ENV['USER'], ENV['LOGNAME']].join('|')"
      ],
      chdir: Rails.root.to_s
    )

    expected_home = Rails.root.join("tmp", "rundiff", "home").to_s
    assert_equal Rails.root.to_s, identity.prepared_workspace
    assert_equal "#{expected_home}|rundiff-subject|rundiff-subject", output
  end

  test "failure diagnostics report environment keys without values" do
    runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new(
      host_env: { "PATH" => ENV.fetch("PATH"), "HOME" => "/safe/home" }
    )

    error = assert_raises(RunDiff::Github::LocalPullRequestRunner::Error) do
      runner.call(
        env: { "RUNDIFF_SECRET_SENTINEL" => "do-not-print-this-value" },
        command: [ RbConfig.ruby, "-e", "warn 'expected failure'; exit 1" ],
        chdir: Rails.root.to_s
      )
    end

    assert_includes error.message, "expected failure"
    assert_includes error.message, "Effective environment keys:"
    assert_includes error.message, "RUNDIFF_SECRET_SENTINEL"
    refute_includes error.message, "do-not-print-this-value"
  end
end
