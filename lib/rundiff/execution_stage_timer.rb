require "fileutils"
require "json"
require "time"

module RunDiff
  class ExecutionStageTimer
    def initialize(
      logger: ::Rails.logger,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      metrics_path: ENV["RUNDIFF_STAGE_METRICS_PATH"]
    )
      @logger = logger
      @clock = clock
      @metrics_path = metrics_path.presence
    end

    def measure(execution_id:, stage:, role: nil, implementation: "ruby")
      started_at = @clock.call
      result = yield
      emit(
        execution_id:,
        stage:,
        role:,
        implementation:,
        elapsed_ms: elapsed_ms(started_at),
        outcome: "ok"
      )
      result
    rescue StandardError => error
      emit(
        execution_id:,
        stage:,
        role:,
        implementation:,
        elapsed_ms: elapsed_ms(started_at),
        outcome: "error",
        error_class: error.class.name
      )
      raise
    end

    private

    def elapsed_ms(started_at)
      ((@clock.call - started_at) * 1_000).round
    end

    def emit(execution_id:, stage:, role:, implementation:, elapsed_ms:, outcome:, error_class: nil)
      log(
        execution_id:,
        stage:,
        role:,
        implementation:,
        elapsed_ms:,
        outcome:,
        error_class:
      )
      append_metric(
        execution_id:,
        stage:,
        role:,
        implementation:,
        elapsed_ms:,
        outcome:,
        error_class:
      )
    end

    def log(execution_id:, stage:, role:, implementation:, elapsed_ms:, outcome:, error_class: nil)
      fields = [
        "RunDiff execution stage",
        "execution_id=#{execution_id.to_s.inspect}",
        "implementation=#{implementation.to_s.inspect}",
        "stage=#{stage.to_s.inspect}",
        ("role=#{role.to_s.inspect}" if role),
        "elapsed_ms=#{Integer(elapsed_ms)}",
        "outcome=#{outcome.inspect}",
        ("error_class=#{error_class.inspect}" if error_class)
      ].compact

      @logger.info(fields.join(" "))
    end

    def append_metric(execution_id:, stage:, role:, implementation:, elapsed_ms:, outcome:, error_class:)
      return unless @metrics_path

      FileUtils.mkdir_p(File.dirname(@metrics_path))
      event = {
        schema_version: "1",
        at: Time.now.utc.iso8601(6),
        execution_id: execution_id.to_s,
        implementation: implementation.to_s,
        phase: stage.to_s,
        role: role&.to_s,
        duration_ms: Integer(elapsed_ms),
        outcome: outcome.to_s,
        error_class: error_class
      }.compact

      File.open(@metrics_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(JSON.generate(event))
        file.write("\n")
      end
    end
  end
end
