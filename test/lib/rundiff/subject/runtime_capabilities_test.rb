require "test_helper"

class RunDiffSubjectRuntimeCapabilitiesTest < ActiveSupport::TestCase
  test "stores declared runtime, package-manager, and service-provider versions" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.new(
      runtimes: {
        ruby: "3.4.10",
        node: "24.0.0"
      },
      package_managers: {
        pnpm: "10.0.0"
      },
      service_providers: {
        compose: "2.40.0"
      }
    )

    assert capabilities.runtime?("ruby")
    assert capabilities.runtime?(:node)
    assert capabilities.package_manager?("pnpm")
    assert capabilities.service_provider?(:compose)
    assert_equal "3.4.10", capabilities.runtime_version("ruby")
    assert_equal "24.0.0", capabilities.runtime_version(:node)
    assert_equal "10.0.0", capabilities.package_manager_version(:pnpm)
    assert_equal "2.40.0", capabilities.service_provider_version("compose")
    assert_equal(
      {
        "runtimes" => {
          "ruby" => "3.4.10",
          "node" => "24.0.0"
        },
        "package_managers" => {
          "pnpm" => "10.0.0"
        },
        "service_providers" => {
          "compose" => "2.40.0"
        }
      },
      capabilities.to_h
    )
  end

  test "ruby_only declares the current Ruby and no JavaScript tooling or service providers" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.ruby_only(version: "3.4.10")

    assert_equal "3.4.10", capabilities.runtime_version("ruby")
    refute capabilities.runtime?("node")
    refute capabilities.runtime?("bun")
    refute capabilities.package_manager?("npm")
    refute capabilities.package_manager?("pnpm")
    refute capabilities.package_manager?("yarn")
    refute capabilities.package_manager?("bun")
    refute capabilities.service_provider?("compose")
  end

  test "loads executor capabilities from an explicit JSON environment declaration" do
    env = {
      RunDiff::Subject::RuntimeCapabilities::ENV_KEY => JSON.generate(
        "runtimes" => {
          "ruby" => "3.4.10",
          "node" => "24.20.0"
        },
        "package_managers" => {
          "npm" => "11.19.0"
        },
        "service_providers" => {
          "compose" => "2.40.0"
        }
      )
    }

    capabilities = RunDiff::Subject::RuntimeCapabilities.from_env(env:, ruby_version: "3.4.10")

    assert_equal "3.4.10", capabilities.runtime_version("ruby")
    assert_equal "24.20.0", capabilities.runtime_version("node")
    assert_equal "11.19.0", capabilities.package_manager_version("npm")
    assert_equal "2.40.0", capabilities.service_provider_version("compose")
  end

  test "falls back to Ruby-only capabilities when the executor declaration is absent" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.from_env(env: {}, ruby_version: "3.4.10")

    assert_equal "3.4.10", capabilities.runtime_version("ruby")
    refute capabilities.runtime?("node")
    refute capabilities.package_manager?("npm")
    refute capabilities.service_provider?("compose")
  end

  test "adds a service provider discovered through an isolated provider handshake" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.new(
      runtimes: { ruby: "3.4.10" },
      package_managers: {},
      service_providers: {}
    )

    discovered = capabilities.with_service_provider("compose", "1")

    refute capabilities.service_provider?("compose")
    assert discovered.service_provider?("compose")
    assert_equal "1", discovered.service_provider_version("compose")
  end

  test "rejects a discovered service-provider version that conflicts with the declaration" do
    capabilities = RunDiff::Subject::RuntimeCapabilities.new(
      runtimes: { ruby: "3.4.10" },
      package_managers: {},
      service_providers: { compose: "old" }
    )

    error = assert_raises(RunDiff::Subject::RuntimeCapabilities::Error) do
      capabilities.with_service_provider("compose", "1")
    end

    assert_includes error.message, "conflicts"
    assert_includes error.message, 'declared="old"'
    assert_includes error.message, 'discovered="1"'
  end

  test "rejects invalid executor capability JSON instead of probing the host" do
    env = {
      RunDiff::Subject::RuntimeCapabilities::ENV_KEY => "{"
    }

    error = assert_raises(RunDiff::Subject::RuntimeCapabilities::Error) do
      RunDiff::Subject::RuntimeCapabilities.from_env(env:, ruby_version: "3.4.10")
    end

    assert_match(/Invalid RUNDIFF_EXECUTOR_CAPABILITIES_JSON/, error.message)
  end

  test "rejects non-object executor capability JSON" do
    env = {
      RunDiff::Subject::RuntimeCapabilities::ENV_KEY => "[]"
    }

    error = assert_raises(RunDiff::Subject::RuntimeCapabilities::Error) do
      RunDiff::Subject::RuntimeCapabilities.from_env(env:, ruby_version: "3.4.10")
    end

    assert_equal "RUNDIFF_EXECUTOR_CAPABILITIES_JSON must contain a JSON object", error.message
  end

  test "rejects capabilities without a version" do
    error = assert_raises(RunDiff::Subject::RuntimeCapabilities::Error) do
      RunDiff::Subject::RuntimeCapabilities.new(
        runtimes: { ruby: "" },
        package_managers: {}
      )
    end

    assert_equal 'Executor runtime capability "ruby" must declare a version', error.message
  end

  test "rejects non-mapping capability declarations" do
    error = assert_raises(RunDiff::Subject::RuntimeCapabilities::Error) do
      RunDiff::Subject::RuntimeCapabilities.new(
        runtimes: [ "ruby" ],
        package_managers: {}
      )
    end

    assert_equal "Executor runtime capabilities must be a mapping", error.message
  end
end
