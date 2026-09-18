module RunDiff
  module Rails
    class SourceLocator
      EXCLUDED_PREFIXES = %w[.bundle/ lib/rundiff/ log/ storage/ tmp/ vendor/].freeze

      def self.call(locations: caller_locations(1, 100))
        new(locations:).call
      end

      def initialize(locations:)
        @locations = locations
      end

      def call
        root = "#{::Rails.root.expand_path}/"

        @locations.each do |location|
          absolute_path = location.absolute_path || location.path
          next unless absolute_path&.start_with?(root)

          path = absolute_path.delete_prefix(root)
          next if EXCLUDED_PREFIXES.any? { |prefix| path.start_with?(prefix) }

          return {
            path:,
            start_line: location.lineno,
            end_line: location.lineno
          }
        end

        nil
      end
    end
  end
end
