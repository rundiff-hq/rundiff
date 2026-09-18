require "pathname"

module RunDiff
  module Subject
    class RailsSetupPlanDetector
      Error = Class.new(StandardError)

      def initialize(javascript_package_manager_detector: JavascriptPackageManagerDetector.new)
        @javascript_package_manager_detector = javascript_package_manager_detector
      end

      def call(root:, configuration:)
        root = Pathname(root)
        return unless rails_subject?(root)

        assert_lockfile!(root)
        javascript = @javascript_package_manager_detector.call(root:)

        steps = [ ruby_bootstrap_step ]
        steps << javascript.bootstrap_step if javascript
        steps.concat([
          {
            phase: "prepare",
            operation: "rails.db_prepare",
            provenance: "detected",
            details: {
              task: "db:prepare",
              persistence_mode: configuration.persistence
            }
          },
          {
            phase: "cleanup",
            operation: "subject.state_cleanup",
            provenance: "executor_default"
          }
        ])

        evidence = evidence_for(root)
        evidence.merge!(javascript.evidence) if javascript

        SetupPlan.new(
          framework: "rails",
          steps:,
          evidence:
        )
      end

      private

      def ruby_bootstrap_step
        {
          phase: "bootstrap",
          operation: "ruby.bundle",
          provenance: "detected",
          details: {
            manifest: "Gemfile",
            lockfile: "Gemfile.lock"
          }
        }
      end

      def rails_subject?(root)
        root.join("Gemfile").file? && root.join("bin", "rails").file?
      end

      def assert_lockfile!(root)
        return if root.join("Gemfile.lock").file?

        raise Error, "Rails subject requires a committed Gemfile.lock for reproducible setup"
      end

      def evidence_for(root)
        {
          "gemfile" => true,
          "gemfile_lock" => true,
          "bin_rails" => true,
          "bin_setup" => root.join("bin", "setup").file?,
          "ruby_version" => root.join(".ruby-version").file? ? ".ruby-version" : nil
        }.compact
      end
    end
  end
end
