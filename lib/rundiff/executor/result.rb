module RunDiff
  module Executor
    Result = Data.define(
      :schema_version,
      :status,
      :payload,
      :error_class,
      :error_message
    ) do
      def self.current_schema_version
        "1"
      end

      def self.statuses
        @statuses ||= %w[succeeded failed].freeze
      end

      def self.success(payload)
        new(
          schema_version: current_schema_version,
          status: "succeeded",
          payload:,
          error_class: nil,
          error_message: nil
        )
      end

      def self.failure(error)
        new(
          schema_version: current_schema_version,
          status: "failed",
          payload: nil,
          error_class: error.class.to_s,
          error_message: error.message.to_s
        )
      end

      def self.from_h(payload)
        payload = payload.transform_keys(&:to_s)
        schema_version = payload.fetch("schema_version")
        unless schema_version == current_schema_version
          raise ArgumentError, "Unsupported executor result schema #{schema_version.inspect}"
        end

        status = payload.fetch("status")
        raise ArgumentError, "Unsupported executor result status #{status.inspect}" unless statuses.include?(status)

        new(
          schema_version:,
          status:,
          payload: payload["payload"],
          error_class: payload["error_class"],
          error_message: payload["error_message"]
        )
      end

      def success?
        status == "succeeded"
      end

      def failure?
        status == "failed"
      end

      def to_h
        {
          "schema_version" => schema_version,
          "status" => status,
          "payload" => payload,
          "error_class" => error_class,
          "error_message" => error_message
        }
      end
    end
  end
end
