require "test_helper"
require "net/http"
require "rbconfig"
require "socket"
require "timeout"
require "uri"

class RunDiffSubjectLifecycleProcessServiceTest < ActiveSupport::TestCase
  Configuration = Data.define(:capture_env)

  class HttpProcessEnvironment < RunDiff::Subject::Environment
    READINESS_TIMEOUT_SECONDS = 5
    STOP_TIMEOUT_SECONDS = 2

    attr_reader :port, :stopped_pid

    def initialize(fixture_path:, fail_healthcheck: false)
      @fixture_path = fixture_path
      @fail_healthcheck = fail_healthcheck
    end

    def prepare(root:, execution:, role:)
      @port = allocate_port
      {
        "RUNDIFF_TEST_SERVICE_URL" => "http://127.0.0.1:#{port}"
      }
    end

    def env_for(root:, execution:, role:)
      {
        "RUNDIFF_TEST_SERVICE_URL" => "http://127.0.0.1:#{port}"
      }
    end

    def start_services(root:, execution:, role:, env:)
      @pid = Process.spawn(
        RbConfig.ruby,
        @fixture_path.to_s,
        port.to_s,
        out: File::NULL,
        err: File::NULL
      )
    end

    def healthcheck(root:, execution:, role:, env:)
      wait_until_ready(env.fetch("RUNDIFF_TEST_SERVICE_URL"))
      raise "forced readiness failure" if @fail_healthcheck
    end

    def stop_services(root:, execution:, role:, env:)
      stop_process
    end

    def cleanup(root:, execution:, role:)
      stop_process
    end

    def process_alive?(pid = @pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    private

    def allocate_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr.fetch(1)
    ensure
      server&.close
    end

    def wait_until_ready(base_url)
      Timeout.timeout(READINESS_TIMEOUT_SECONDS) do
        loop do
          begin
            response = Net::HTTP.get_response(URI("#{base_url}/health"))
            return if response.is_a?(Net::HTTPSuccess)
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
            raise "HTTP service exited before readiness" unless process_alive?
          end

          sleep 0.02
        end
      end
    end

    def stop_process
      pid = @pid
      return unless pid

      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end

      begin
        Timeout.timeout(STOP_TIMEOUT_SECONDS) { Process.wait(pid) }
      rescue Timeout::Error
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      ensure
        @stopped_pid = pid
        @pid = nil
      end
    end
  end

  test "starts a real HTTP service on a dynamic port and tears it down after capture" do
    environment = build_environment
    lifecycle = build_lifecycle(environment:)

    lifecycle.open(
      root: Rails.root,
      execution: Object.new,
      role: "candidate",
      configuration: Configuration.new(capture_env: {})
    ) do |session|
      assert_operator environment.port, :>, 0
      assert environment.process_alive?
      assert_equal "service-ready", Net::HTTP.get(URI("#{session.env.fetch("RUNDIFF_TEST_SERVICE_URL")}/value"))
    end

    refute environment.process_alive?(environment.stopped_pid)
    assert_raises(Errno::ECONNREFUSED) do
      TCPSocket.new("127.0.0.1", environment.port)
    end
  end

  test "tears down the real HTTP service when readiness fails" do
    environment = build_environment(fail_healthcheck: true)
    lifecycle = build_lifecycle(environment:)

    error = assert_raises(RuntimeError) do
      lifecycle.open(
        root: Rails.root,
        execution: Object.new,
        role: "base",
        configuration: Configuration.new(capture_env: {})
      ) { flunk "capture must not run after readiness failure" }
    end

    assert_equal "forced readiness failure", error.message
    refute environment.process_alive?(environment.stopped_pid)
    assert_raises(Errno::ECONNREFUSED) do
      TCPSocket.new("127.0.0.1", environment.port)
    end
  end

  private

  def build_environment(fail_healthcheck: false)
    HttpProcessEnvironment.new(
      fixture_path: Rails.root.join("test", "fixtures", "subject_service", "http_service.rb"),
      fail_healthcheck:
    )
  end

  def build_lifecycle(environment:)
    RunDiff::Subject::Lifecycle.new(
      discovery: nil,
      environment:
    )
  end
end
