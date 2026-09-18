module RunDiff
  module Executor
    class RepositoryCapability
      HEADER = "RunDiff-Repository-Authorization".freeze

      attr_reader :token

      def self.from_header(value)
        value = value.to_s
        return nil if value.empty?

        scheme, token = value.split(" ", 2)
        unless scheme == "Bearer" && token && !token.empty?
          raise ArgumentError, "Invalid repository capability authorization"
        end

        new(token:)
      end

      def initialize(token:)
        @token = token.to_s
        raise ArgumentError, "Repository capability token is required" if @token.empty?
      end

      def authorization_header
        "Bearer #{@token}"
      end

      def inspect
        "#<#{self.class.name} token=[FILTERED]>"
      end
    end
  end
end
