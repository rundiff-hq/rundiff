#!/usr/bin/env ruby

require "active_support/core_ext/object/blank"
require "digest"
require "fileutils"
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

module YarnBerryExecutorCapabilityProof
  EXPECTED_NODE_VERSION = "24.20.0"
  EXPECTED_YARN_VERSION = "4.18.0"

  module_function

  def call
    capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
    assert_capabilities!(capabilities)

    command_runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new
    node_runtime = run_version!(command_runner, %w[node --version])
    yarn_runtime = run_version!(command_runner, %w[yarn --version])

    unless node_runtime == "v#{EXPECTED_NODE_VERSION}"
      raise "Declared Node capability does not match runtime: #{node_runtime.inspect}"
    end
    unless yarn_runtime == EXPECTED_YARN_VERSION
      raise "Declared Yarn capability does not match runtime: #{yarn_runtime.inspect}"
    end

    Dir.mktmpdir("rundiff-yarn-berry-capability-") do |directory|
      root = Pathname(directory)
      write_subject(root)
      generate_lockfile!(command_runner, root)
      remove_generated_install_state!(root)

      detection = RunDiff::Subject::JavascriptPackageManagerDetector.new.call(root:)
      unless detection&.manager == "yarn" && detection.lockfile == "yarn.lock"
        raise "Expected Yarn package-manager detection from yarn.lock"
      end
      unless detection.yarn_generation == "berry"
        raise "Expected Yarn Berry generation evidence"
      end
      unless detection.package_manager_version == EXPECTED_YARN_VERSION
        raise "Expected exact Yarn packageManager version evidence"
      end

      manifest = root.join("package.json")
      lockfile = root.join("yarn.lock")
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

      pnp_runtime = root.join(".pnp.cjs")
      raise "Yarn immutable install did not recreate the PnP runtime" unless pnp_runtime.file?
      assert_digest!(manifest, manifest_digest, label: "package.json")
      assert_digest!(lockfile, lockfile_digest, label: "yarn.lock")

      dependency_runtime = command_runner.call(
        env: {},
        command: [
          "yarn",
          "node",
          "-e",
          "process.stdout.write(process.version + ':' + String(require('is-number')(42)))"
        ],
        chdir: root.to_s
      ).strip
      expected_dependency_runtime = "v#{EXPECTED_NODE_VERSION}:true"
      unless dependency_runtime == expected_dependency_runtime
        raise "Yarn-installed dependency used unexpected runtime: #{dependency_runtime.inspect}"
      end

      puts "Yarn Berry executor capability proof"
      puts "executor_node_capability=#{capabilities.runtime_version("node")}"
      puts "executor_yarn_capability=#{capabilities.package_manager_version("yarn")}"
      puts "node_runtime=#{node_runtime}"
      puts "yarn_runtime=#{yarn_runtime}"
      puts "javascript_package_manager=yarn"
      puts "yarn_generation=berry"
      puts "package_manager_version_contract=matched"
      puts "dependency_bootstrap=yarn_install_immutable"
      puts "customer_dependency_runtime=#{dependency_runtime}"
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
    unless capabilities.package_manager_version("yarn") == EXPECTED_YARN_VERSION
      raise "Expected declared Yarn capability #{EXPECTED_YARN_VERSION}"
    end
  end

  def run_version!(command_runner, command)
    command_runner.call(env: {}, command:, chdir: TOOL_ROOT.to_s).strip
  end

  def generate_lockfile!(command_runner, root)
    command_runner.call(
      env: {},
      command: %w[yarn install --mode=skip-build],
      chdir: root.to_s
    )

    lockfile = root.join("yarn.lock")
    raise "Yarn did not generate yarn.lock for the proof subject" unless lockfile.file?
  end

  def remove_generated_install_state!(root)
    FileUtils.rm_f(root.join(".pnp.cjs"))
    FileUtils.rm_f(root.join(".pnp.loader.mjs"))
    FileUtils.rm_rf(root.join(".yarn"))
  end

  def write_subject(root)
    package = {
      "name" => "rundiff-yarn-berry-capability-proof",
      "version" => "1.0.0",
      "private" => true,
      "packageManager" => "yarn@#{EXPECTED_YARN_VERSION}",
      "dependencies" => {
        "is-number" => "7.0.0"
      }
    }

    root.join("package.json").write("#{JSON.pretty_generate(package)}\n")
  end

  def assert_digest!(path, expected_digest, label:)
    actual_digest = Digest::SHA256.file(path).hexdigest
    return if actual_digest == expected_digest

    raise "Yarn bootstrap mutated committed #{label}"
  end
end

YarnBerryExecutorCapabilityProof.call
