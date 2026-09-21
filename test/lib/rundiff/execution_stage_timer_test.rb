require "test_helper"

class RunDiffExecutionStageTimerTest < ActiveSupport::TestCase
  FakeLogger = Struct.new(:messages) do
    def info(message)
      messages << message
    end
  end

  test "logs execution stage elapsed time without payload data" do
    values = [ 10.0, 10.125 ]
    logger = FakeLogger.new([])
    timer = RunDiff::ExecutionStageTimer.new(
      logger:,
      clock: -> { values.shift },
      metrics_path: nil
    )

    result = timer.measure(
      execution_id: "github-123",
      stage: "bootstrap",
      role: "base"
    ) do
      "secret-result"
    end

    assert_equal "secret-result", result
    message = logger.messages.fetch(0)
    assert_includes message, 'execution_id="github-123"'
    assert_includes message, 'implementation="ruby"'
    assert_includes message, 'stage="bootstrap"'
    assert_includes message, 'role="base"'
    assert_includes message, "elapsed_ms=125"
    assert_includes message, 'outcome="ok"'
    refute_includes message, "secret-result"
  end

  test "logs only the error class before re-raising" do
    values = [ 20.0, 20.05 ]
    logger = FakeLogger.new([])
    timer = RunDiff::ExecutionStageTimer.new(
      logger:,
      clock: -> { values.shift },
      metrics_path: nil
    )

    error = assert_raises(RuntimeError) do
      timer.measure(
        execution_id: "github-456",
        stage: "capture",
        role: "candidate"
      ) do
        raise "do-not-log-this-message"
      end
    end

    assert_equal "do-not-log-this-message", error.message
    message = logger.messages.fetch(0)
    assert_includes message, 'outcome="error"'
    assert_includes message, 'error_class="RuntimeError"'
    refute_includes message, "do-not-log-this-message"
  end
end


class RunDiffExecutionStageTimerMetricsTest < ActiveSupport::TestCase
  FakeLogger = Struct.new(:messages) do
    def info(message)
      messages << message
    end
  end

  test "appends safe JSONL phase metrics" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "phase-metrics.jsonl")
      values = [ 1.0, 1.25 ]
      timer = RunDiff::ExecutionStageTimer.new(
        logger: FakeLogger.new([]),
        clock: -> { values.shift },
        metrics_path: path
      )

      timer.measure(
        execution_id: "github-metric",
        stage: "clone",
        implementation: "ruby"
      ) { :ok }

      event = JSON.parse(File.read(path))
      assert_equal "1", event.fetch("schema_version")
      assert_equal "github-metric", event.fetch("execution_id")
      assert_equal "ruby", event.fetch("implementation")
      assert_equal "clone", event.fetch("phase")
      assert_equal 250, event.fetch("duration_ms")
      assert_equal "ok", event.fetch("outcome")
      refute event.key?("payload")
    end
  end
end
