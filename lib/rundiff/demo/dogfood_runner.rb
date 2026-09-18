require "json"
require "rack/mock"
require "securerandom"

module RunDiff
  module Demo
    class DogfoodRunner
      PATH = "/__rundiff/demo/behavior"
      SCENARIO_ID = "dogfood.rails.behavior"

      def self.call
        new.call
      end

      def call
        raise "RunDiff dogfood runner is only available in development and test" unless ::Rails.env.development? || ::Rails.env.test?

        warm_runtime
        run_id = SecureRandom.uuid
        baseline = execute(run_id:, subject: "baseline")
        candidate = execute(run_id:, subject: "candidate")
        result = RunDiff::BehavioralDiff.call(
          baseline: baseline.fetch("measurements"),
          candidate: candidate.fetch("measurements")
        )

        {
          "schema_version" => "1",
          "run_id" => run_id,
          "scenario_id" => SCENARIO_ID,
          "executions" => {
            "baseline" => baseline,
            "candidate" => candidate
          },
          "result" => result
        }
      end

      private

      def warm_runtime
        ApplicationRecord.connection.select_value("SELECT 1")
        request.post(PATH, headers(subject: "warmup", execution_id: "warmup", run_id: "warmup"))
      end

      def execute(run_id:, subject:)
        execution_id = SecureRandom.uuid
        response = nil
        measurements = RunDiff::Rails::EvidenceCollector.capture(execution_id:) do
          response = request.post(PATH, headers(subject:, execution_id:, run_id:))
        end

        passed = response.status.between?(200, 299)
        measurements["errors"] += 1 unless passed

        {
          "execution_id" => execution_id,
          "run_id" => run_id,
          "scenario_id" => SCENARIO_ID,
          "subject" => subject,
          "status" => passed ? "passed" : "failed",
          "http_status" => response.status,
          "correlation_confirmed" => response["X-RunDiff-Execution-Id"] == execution_id,
          "measurements" => measurements
        }
      end

      def request
        @request ||= Rack::MockRequest.new(::Rails.application)
      end

      def headers(subject:, execution_id:, run_id:)
        {
          "HTTP_HOST" => "localhost",
          "HTTP_X_RUNDIFF_EXECUTION_ID" => execution_id,
          "HTTP_X_RUNDIFF_RUN_ID" => run_id,
          "HTTP_X_RUNDIFF_SUBJECT" => subject
        }
      end
    end
  end
end
