module RunDiff
  module Execution
    class OrchestratorDispatch
      Error = Class.new(StandardError)
      MODES = %w[native github_actions].freeze

      def initialize(
        mode: ENV.fetch("RUNDIFF_EXECUTION_ORCHESTRATOR", "native"),
        executor_job: RunDiffExecutorJob
      )
        @mode = mode.to_s
        @executor_job = executor_job

        return if MODES.include?(@mode)

        raise Error, "Unsupported RUNDIFF_EXECUTION_ORCHESTRATOR=#{@mode.inspect}"
      end

      def call(request:)
        case @mode
        when "native"
          @executor_job.perform_later(request.to_h)
          "native"
        when "github_actions"
          "github_actions"
        else
          raise Error, "Unsupported execution orchestrator #{@mode.inspect}"
        end
      end
    end
  end
end
