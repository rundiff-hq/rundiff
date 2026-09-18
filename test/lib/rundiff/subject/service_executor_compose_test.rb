require "test_helper"
require "socket"
require "tmpdir"

class RunDiffSubjectServiceExecutorComposeTest < ActiveSupport::TestCase
  class TcpComposeProvider
    attr_reader :stopped

    def start(root:, role:, step:)
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new do
        loop do
          client = @server.accept
          client.close
        rescue IOError, Errno::EBADF
          break
        end
      end
      handle = Data.define(:id).new(id: "compose-handle")
      RunDiff::Subject::ComposeServiceProvider::Started.new(
        handle:,
        host: "127.0.0.1",
        port: @server.addr[1]
      )
    end

    def diagnostics(handle)
      "compose diagnostics"
    end

    def stop(handle)
      @stopped = true
      @server&.close
      @thread&.join(1)
    end
  end

  test "starts Compose provider, exports typed URL, waits for TCP readiness, and stops it" do
    Dir.mktmpdir("rundiff-compose-executor-") do |directory|
      provider = TcpComposeProvider.new
      executor = RunDiff::Subject::ServiceExecutor.new(compose_provider: provider)
      plan = compose_plan
      result = executor.start(
        root: Pathname(directory),
        execution: Object.new,
        role: "candidate",
        env: {},
        setup_plan: plan
      )

      service = result.session.services.fetch(0)
      assert_equal "compose", service.kind
      assert_match(%r{\Aredis://127\.0\.0\.1:\d+\z}, result.env.fetch("REDIS_URL"))

      executor.healthcheck(
        root: Pathname(directory),
        execution: Object.new,
        role: "candidate",
        env: result.env,
        setup_plan: plan,
        session: result.session
      )

      executor.stop(
        root: Pathname(directory),
        execution: Object.new,
        role: "candidate",
        env: result.env,
        setup_plan: plan,
        session: result.session
      )

      assert provider.stopped
      refute result.session.state_dir.exist?
    end
  end

  test "fails closed when Compose steps reach an executor without a provider" do
    Dir.mktmpdir("rundiff-compose-executor-") do |directory|
      error = assert_raises(RunDiff::Subject::ServiceExecutor::Error) do
        RunDiff::Subject::ServiceExecutor.new.start(
          root: Pathname(directory),
          execution: Object.new,
          role: "candidate",
          env: {},
          setup_plan: compose_plan
        )
      end

      assert_includes error.message, "Compose service provider is unavailable"
    end
  end

  private

  def compose_plan
    RunDiff::Subject::SetupPlan.new(
      framework: "test",
      steps: [
        {
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
        },
        {
          phase: "healthcheck",
          operation: "tcp.wait_ready",
          provenance: "explicit",
          details: {
            name: "cache",
            url_env: "REDIS_URL",
            timeout_seconds: 2
          }
        },
        {
          phase: "stop_services",
          operation: "compose.stop",
          provenance: "explicit",
          details: { name: "cache" }
        }
      ]
    )
  end
end
