module RunDiff
  module Subject
    class Environment
      EMPTY_CAPABILITIES = [].freeze

      def capabilities
        EMPTY_CAPABILITIES
      end

      def capability?(name)
        capabilities.include?(name.to_s)
      end

      def capabilities_for(namespace)
        prefix = "#{namespace}."

        capabilities.filter_map do |capability|
          capability.delete_prefix(prefix) if capability.start_with?(prefix)
        end
      end

      def prepare(root:, execution:, role:, sample_index: nil)
        raise NotImplementedError
      end

      def env_for(root:, execution:, role:, sample_index: nil)
        raise NotImplementedError
      end

      def start_services(root:, execution:, role:, env:)
        nil
      end

      def healthcheck(root:, execution:, role:, env:)
        nil
      end

      def stop_services(root:, execution:, role:, env:)
        nil
      end

      def cleanup(root:, execution:, role:, sample_index: nil)
        nil
      end
    end
  end
end
