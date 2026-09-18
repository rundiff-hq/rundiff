module RunDiff
  module Subject
    class BootstrapExecutor
      Error = Class.new(StandardError)

      def initialize(ruby_bundle_bootstrap:, runtime_capabilities:, javascript_dependencies_bootstrap: nil)
        @ruby_bundle_bootstrap = ruby_bundle_bootstrap
        @javascript_dependencies_bootstrap = javascript_dependencies_bootstrap
        @runtime_capabilities = runtime_capabilities
      end

      def call(root:, setup_plan:)
        raise Error, "Subject setup plan is required for bootstrap execution" unless setup_plan

        setup_plan.steps_for("bootstrap").each_with_object({}) do |step, environment|
          step_environment = execute_step(root:, step:)
          merge_environment!(environment, step_environment, operation: step.operation)
        end
      end

      private

      def execute_step(root:, step:)
        case step.operation
        when "ruby.bundle"
          assert_runtime!("ruby", operation: step.operation)
          assert_ruby_bundle_step!(step)
          @ruby_bundle_bootstrap.call(root:)
        when "javascript.dependencies"
          assert_javascript_dependencies_step!(step)
          assert_javascript_capabilities!(step)
          assert_javascript_handler!
          @javascript_dependencies_bootstrap.call(root:, step:)
        else
          raise Error, "Unsupported bootstrap operation #{step.operation.inspect}"
        end
      end

      def assert_ruby_bundle_step!(step)
        manifest = step.details.fetch("manifest", nil)
        lockfile = step.details.fetch("lockfile", nil)
        return if manifest == "Gemfile" && lockfile == "Gemfile.lock"

        raise Error,
          "ruby.bundle setup step must use Gemfile and Gemfile.lock; " \
          "received manifest=#{manifest.inspect} lockfile=#{lockfile.inspect}"
      end

      def assert_javascript_dependencies_step!(step)
        manager = step.details.fetch("manager", nil).to_s
        manifest = step.details.fetch("manifest", nil)
        lockfile = step.details.fetch("lockfile", nil)
        frozen_lockfile = step.details.fetch("frozen_lockfile", nil)

        if manager.empty? || manifest != "package.json" || lockfile.to_s.empty? || frozen_lockfile != true
          raise Error,
            "javascript.dependencies setup step must declare manager, package.json, lockfile, and frozen_lockfile=true"
        end
      end

      def assert_javascript_capabilities!(step)
        manager = step.details.fetch("manager").to_s
        requested_version = step.details.fetch("package_manager_version", nil)&.to_s

        if manager == "bun"
          assert_runtime!("bun", operation: step.operation)
        else
          assert_runtime!("node", operation: step.operation)
        end
        assert_package_manager!(manager, operation: step.operation, requested_version:)
      end

      def assert_javascript_handler!
        return if @javascript_dependencies_bootstrap

        raise Error, "Bootstrap operation javascript.dependencies has no typed handler configured"
      end

      def assert_runtime!(name, operation:)
        return if @runtime_capabilities.runtime?(name)

        raise Error,
          "Bootstrap operation #{operation} requires executor runtime capability #{name.inspect}"
      end

      def assert_package_manager!(name, operation:, requested_version: nil)
        unless @runtime_capabilities.package_manager?(name)
          raise Error,
            "Bootstrap operation #{operation} requires executor package-manager capability #{name.inspect}"
        end

        return if requested_version.nil? || requested_version.empty?

        executor_version = @runtime_capabilities.package_manager_version(name)
        return if executor_version == requested_version

        raise Error,
          "Bootstrap operation #{operation} requires #{name}@#{requested_version}, " \
          "but executor declares #{name}@#{executor_version}"
      end

      def merge_environment!(environment, addition, operation:)
        unless addition.is_a?(Hash)
          raise Error, "Bootstrap operation #{operation.inspect} must return an environment mapping"
        end

        addition.each do |key, value|
          key = key.to_s
          if environment.key?(key) && environment.fetch(key) != value
            raise Error, "Bootstrap operations produced conflicting values for environment key #{key.inspect}"
          end

          environment[key] = value
        end
      end
    end
  end
end
