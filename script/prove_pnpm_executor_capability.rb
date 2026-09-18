#!/usr/bin/env ruby

require "active_support/core_ext/object/blank"
require "digest"
require "json"
require "pathname"
require "tmpdir"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze

require TOOL_ROOT.join("lib", "rundiff", "subject", "runtime_capabilities").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "bootstrap_executor").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "javascript_package_manager_detector").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "javascript_dependencies_bootstrap").to_s
require TOOL_ROOT.join("lib", "rundiff", "github", "local_pull_request_runner").to_s

module PnpmExecutorCapabilityProof
  EXPECTED_NODE_VERSION = "24.20.0"
  EXPECTED_PNPM_VERSION = "12.3.4"

  module_function

  def call
    capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
    assert_capabilities!(capabilities)

    command_runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new
    node_runtime = run_version!(command_runner, %w[node --version])
    pnpm_runtime = run_version!(command_runner, %w[pnpm --version])

    unless node_runtime == "v#{EXPECTED_NODE_VERSION}"
      raise "Declared Node capability does not match runtime: #{node_runtime.inspect}"
    end
    unless pnpm_runtime == EXPECTED_PNPM_VERSION
      raise "Declared pnpm capability does not match runtime: #{pnpm_runtime.inspect}"
    end

    Dir.mktmpdir("rundiff-pnpm-capability-") do |directory|
      root = Pathname(directory)
      write_subject(root)
      generate_lockfile!(command_runner, root)

      marker = root.join("pnpm-bootstrap-proof.txt")
      raise "pnpm lockfile generation unexpectedly ran customer scripts" if marker.exist?

      detection = RunDiff::Subject::JavascriptPackageManagerDetector.new.call(root:)
      unless detection&.manager == "pnpm" && detection.lockfile == "pnpm-lock.yaml"
        raise "Expected pnpm package-manager detection from pnpm-lock.yaml"
      end
      unless detection.package_manager_version == EXPECTED_PNPM_VERSION
        raise "Expected exact pnpm packageManager version evidence"
      end

      manifest = root.join("package.json")
      lockfile = root.join("pnpm-lock.yaml")
      manifest_digest = Digest::SHA256.file(manifest).hexdigest
      lockfile_digest = Digest::SHA256.file(lockfile).hexdigest

      javascript_bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner:)
      bootstrap_executor = RunDiff::Subject::BootstrapExecutor.new(
        ruby_bundle_bootstrap: nil,
        javascript_dependencies_bootstrap: javascript_bootstrap,
        runtime_capabilities: capabilities
      )
      setup_plan = RunDiff::Subject::SetupPlan.new(
        framework: "javascript",
        steps: [ detection.bootstrap_step ]
      )
      bootstrap_executor.call(root:, setup_plan:)

      raise "pnpm frozen install did not execute the customer postinstall script" unless marker.file?
      assert_digest!(manifest, manifest_digest, label: "package.json")
      assert_digest!(lockfile, lockfile_digest, label: "pnpm-lock.yaml")

      postinstall_runtime = marker.read.strip
      unless postinstall_runtime == "v#{EXPECTED_NODE_VERSION}"
        raise "Customer postinstall used unexpected Node runtime: #{postinstall_runtime.inspect}"
      end

      puts "pnpm executor capability proof"
      puts "executor_node_capability=#{capabilities.runtime_version("node")}"
      puts "executor_pnpm_capability=#{capabilities.package_manager_version("pnpm")}"
      puts "node_runtime=#{node_runtime}"
      puts "pnpm_runtime=#{pnpm_runtime}"
      puts "javascript_package_manager=pnpm"
      puts "package_manager_version_contract=matched"
      puts "dependency_bootstrap=pnpm_install_frozen_lockfile"
      puts "customer_postinstall_node_runtime=#{postinstall_runtime}"
      puts "committed_dependency_contract_unchanged=true"
    end
  end

  def assert_capabilities!(capabilities)
    unless capabilities.runtime_version("ruby") == RUBY_VERSION
      raise "Executor Ruby capability does not match runtime Ruby #{RUBY_VERSION}"
    end
    unless capabilities.runtime_version("node") == EXPECTED_NODE_VERSION
      raise "Expected declared Node capability #{EXPECTED_NODE_VERSION}"
    end
    unless capabilities.package_manager_version("pnpm") == EXPECTED_PNPM_VERSION
      raise "Expected declared pnpm capability #{EXPECTED_PNPM_VERSION}"
    end
  end

  def run_version!(command_runner, command)
    command_runner.call(env: {}, command:, chdir: TOOL_ROOT.to_s).strip
  end

  def generate_lockfile!(command_runner, root)
    command_runner.call(
      env: {},
      command: %w[pnpm install --lockfile-only --ignore-scripts],
      chdir: root.to_s
    )

    lockfile = root.join("pnpm-lock.yaml")
    raise "pnpm did not generate pnpm-lock.yaml for the proof subject" unless lockfile.file?
  end

  def write_subject(root)
    package = {
      "name" => "rundiff-pnpm-capability-proof",
      "version" => "1.0.0",
      "private" => true,
      "packageManager" => "pnpm@#{EXPECTED_PNPM_VERSION}",
      "scripts" => {
        "postinstall" => "node -e \"require('fs').writeFileSync('pnpm-bootstrap-proof.txt', process.version)\""
      }
    }

    root.join("package.json").write("#{JSON.pretty_generate(package)}\n")
  end

  def assert_digest!(path, expected_digest, label:)
    actual_digest = Digest::SHA256.file(path).hexdigest
    return if actual_digest == expected_digest

    raise "pnpm bootstrap mutated committed #{label}"
  end
end

PnpmExecutorCapabilityProof.call
