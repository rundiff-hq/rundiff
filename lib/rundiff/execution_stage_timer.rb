module RunDiff
  class ExecutionStageTimer
    def initialize(
      logger: Rails.logger,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @logger = logger
      @clock = clock
    end

    def measure(execution_id:, stage:, role: nil)
      started_at = @clock.call
      result = yield
      log(
        execution_id:,
        stage:,
        role:,
        elapsed_ms: elapsed_ms(started_at),
        outcome: "ok"
      )
      result
    rescue StandardError => error
      log(
        execution_id:,
        stage:,
        role:,
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

    def log(execution_id:, stage:, role:, elapsed_ms:, outcome:, error_class: nil)
      fields = [
        "RunDiff execution stage",
        "execution_id=#{execution_id.to_s.inspect}",
        "stage=#{stage.to_s.inspect}",
        ("role=#{role.to_s.inspect}" if role),
        "elapsed_ms=#{Integer(elapsed_ms)}",
        "outcome=#{outcome.inspect}",
        ("error_class=#{error_class.inspect}" if error_class)
      ].compact

      @logger.info(fields.join(" "))
    end
  end
end
