require "test_helper"
require "tmpdir"
require_relative "../../../../lib/rundiff/subject/isolated_compose_provider_client"
require_relative "../../../../lib/rundiff/subject/isolated_compose_provider_server"

class RunDiffSubjectIsolatedComposeProviderTest < ActiveSupport::TestCase
  FakeHandle = Data.define(:project_name)
  FakeStarted = Data.define(:handle, :host, :port)

  class FakeProvider
    attr_reader :starts, :stops

    def initialize
      @starts = []
      @stops = []
    end

    def start(root:, role:, step:)
      root = Pathname(root).realpath
      @starts << {
        root: root.to_s,
        manifest: root.join("compose.yml").read,
        role:,
        step:
      }
      FakeStarted.new(
        handle: FakeHandle.new(project_name: "rundiff-test-project"),
        host: "127.0.0.1",
        port: 49_152
      )
    end

    def diagnostics(_handle)
      "provider diagnostics"
    end

    def stop(handle)
      @stops << handle
    end
  end

  test "handshakes, transfers manifest bytes, and keeps provider workspace separate from customer root" do
    Dir.mktmpdir("rundiff-isolated-provider-") do |directory|
      root = Pathname(directory).join("customer")
      control = Pathname(directory).join("control")
      root.mkpath
      root.join("compose.yml").write("services:\n  redis:\n    image: redis:7-alpine\n")
      socket_path = control.join("provider.sock")
      provider = FakeProvider.new
      server = RunDiff::Subject::IsolatedComposeProviderServer.new(socket_path:, provider:)
      thread = Thread.new { 4.times { server.serve_once } }
      wait_for_socket(socket_path)

      assert_equal 0o600, socket_path.stat.mode & 0o777
      assert_equal 0o700, control.stat.mode & 0o777

      client = RunDiff::Subject::IsolatedComposeProviderClient.new(socket_path:).handshake!
      assert_equal "1", client.provider_version

      started = client.start(root:, role: "candidate", step: compose_start_step)
      assert_equal "127.0.0.1", started.host
      assert_equal 49_152, started.port
      assert_equal "provider diagnostics", client.diagnostics(started.handle)
      client.stop(started.handle)

      thread.join
      call = provider.starts.fetch(0)
      refute_equal root.realpath.to_s, call.fetch(:root)
      assert_equal root.join("compose.yml").read, call.fetch(:manifest)
      refute Pathname(call.fetch(:root)).exist?
      assert_equal "candidate", call.fetch(:role)
      assert_equal "redis", call.fetch(:step).details.fetch("service")
      assert_equal 1, provider.stops.length
    ensure
      server&.shutdown
      thread&.kill
      thread&.join
    end
  end

  test "fails closed when the provider socket is absent" do
    Dir.mktmpdir("rundiff-isolated-provider-") do |directory|
      client = RunDiff::Subject::IsolatedComposeProviderClient.new(
        socket_path: Pathname(directory).join("missing.sock")
      )

      error = assert_raises(RunDiff::Subject::IsolatedComposeProviderClient::Error) do
        client.handshake!
      end

      assert_includes error.message, "Isolated Compose provider is unavailable"
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

  def wait_for_socket(path)
    100.times do
      return if path.socket?

      sleep 0.01
    end

    flunk "provider socket was not created"
  end
end
