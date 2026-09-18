module RunDiff
  module Subject
    StateIdentity = Data.define(:execution_id, :role, :sample_index) do
      EXECUTION_PREFIX_LENGTH = 12

      def self.for(execution:, role:, sample_index: nil)
        new(
          execution_id: execution.execution_id.to_s,
          role: role.to_s,
          sample_index:
        )
      end

      def initialize(execution_id:, role:, sample_index: nil)
        execution_id = execution_id.to_s
        role = role.to_s

        raise ArgumentError, "execution_id is required" if execution_id.empty?
        raise ArgumentError, "role is required" if role.empty?
        unless role.match?(/A[a-z0-9_-]+z/i)
          raise ArgumentError, "role must contain only letters, digits, underscore, or hyphen"
        end

        if sample_index
          sample_index = Integer(sample_index)
          raise ArgumentError, "sample_index must be positive" unless sample_index.positive?
        end

        super(
          execution_id:,
          role:,
          sample_index:
        )
      end

      def suffix
        parts = [ execution_suffix, role ]
        parts << "s#{sample_index}" if sample_index
        parts.join("_")
      end

      private

      def execution_suffix
        execution_id.delete_prefix("github-")[0, EXECUTION_PREFIX_LENGTH]
      end
    end
  end
end
