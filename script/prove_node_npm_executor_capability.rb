#!/usr/bin/env ruby

require "active_support/core_ext/object/blank"
require "json"
require "pathname"
require "tmpdir"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze

require TOOL_ROOT.join("lib", "rundiff", "subject", "runtime_capabilities").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "setup_plan").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "javascript_package_manager_detector").to_s
require TOOL_ROOT.join("lib", "rundiff", "subject", "javascript_dependencies_bootstrap").to_s
require TOOL_ROOT.join("lib", "rundiff", "github", "local_pull_request_runner").to_s

module NodeNpmExecutorCapabilityProof
  EXPECTED_NODE_VERSION = "24.20.0"
  EXPECTED_NPM_VERSION = "11.19.0"

  module_function

  def call
    capabilities = RunDiff::Subject::RuntimeCapabilities.from_env
    assert_capabilities!(capabilities)

    command_runner = RunDiff::Github::LocalPullRequestRunner::CommandRunner.new
    node_runtime = run_version!(command_runner, %w[node --version])
    npm_runtime = run_version!(command_runner, %w[npm --version])

    unless node_runtime == "v#{EXPECTED_NODE_VERSION}"
      raise "Declared Node capability does not match runtime: #{node_runtime.inspect}"
    end
    unless npm_runtime == EXPECTED_NPM_VERSION
      raise "Declared npm capability does not match runtime: #{npm_runtime.inspect}"
    end

    Dir.mktmpdir("rundiff-node-npm-capability-") do |directory|
      root = Pathname(directory)
      write_subject(root)

      detection = RunDiff::Subject::JavascriptPackageManagerDetector.new.call(root:)
      unless detection&.manager == "npm" && detection.lockfile == "package-lock.json"
        raise "Expected npm package-manager detection from package-lock.json"
      end

      bootstrap = RunDiff::Subject::JavascriptDependenciesBootstrap.new(command_runner:)
      bootstrap.call(root:, step: detection.bootstrap_step)

      marker = root.join("npm-bootstrap-proof.txt")
      raise "npm ci did not execute the customer postinstall script" unless marker.file?

      postinstall_runtime = marker.read.strip
      unless postinstall_runtime == "v#{EXPECTED_NODE_VERSION}"
        raise "Customer postinstall used unexpected Node runtime: #{postinstall_runtime.inspect}"
      end

      puts "Node + npm executor capability proof"
      puts "executor_node_capability=#{capabilities.runtime_version("node")}"
      puts "executor_npm_capability=#{capabilities.package_manager_version("npm")}"
      puts "node_runtime=#{node_runtime}"
      puts "npm_runtime=#{npm_runtime}"
      puts "javascript_package_manager=npm"
      puts "dependency_bootstrap=npm_ci"
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
    unless capabilities.package_manager_version("npm") == EXPECTED_NPM_VERSION
      raise "Expected declared npm capability #{EXPECTED_NPM_VERSION}"
    end
  end

  def run_version!(command_runner, command)
    command_runner.call(env: {}, command:, chdir: TOOL_ROOT.to_s).strip
  end

  def write_subject(root)
    package = {
      "name" => "rundiff-node-npm-capability-proof",
      "version" => "1.0.0",
      "private" => true,
      "scripts" => {
        "postinstall" => "node -e \"require('fs').writeFileSync('npm-bootstrap-proof.txt', process.version)\""
      }
    }
    lockfile = {
      "name" => package.fetch("name"),
      "version" => package.fetch("version"),
      "lockfileVersion" => 3,
      "requires" => true,
      "packages" => {
        "" => {
          "name" => package.fetch("name"),
          "version" => package.fetch("version"),
          "hasInstallScript" => true
        }
      }
    }

    root.join("package.json").write("#{JSON.pretty_generate(package)}\n")
    root.join("package-lock.json").write("#{JSON.pretty_generate(lockfile)}\n")
  end
end

NodeNpmExecutorCapabilityProof.call
