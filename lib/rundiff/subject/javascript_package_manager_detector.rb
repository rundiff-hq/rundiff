require "json"
require "pathname"

module RunDiff
  module Subject
    class JavascriptPackageManagerDetector
      Error = Class.new(StandardError)

      SUPPORTED_LOCKFILES = {
        "package-lock.json" => "npm",
        "pnpm-lock.yaml" => "pnpm",
        "yarn.lock" => "yarn",
        "bun.lock" => "bun",
        "bun.lockb" => "bun"
      }.freeze
      SUPPORTED_MANAGERS = SUPPORTED_LOCKFILES.values.uniq.freeze
      EXACT_VERSION_PATTERN = /\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/
      INTEGRITY_PATTERN = /\Asha(?:224|256|384|512)\.[0-9a-fA-F]+\z/

      PackageManagerDeclaration = Data.define(:manager, :version, :integrity)

      Detection = Data.define(
        :manager,
        :manifest,
        :lockfile,
        :package_manager_declaration,
        :package_manager_version,
        :package_manager_integrity,
        :yarn_generation
      ) do
        def bootstrap_step
          SetupPlan::Step.new(
            phase: "bootstrap",
            operation: "javascript.dependencies",
            provenance: "detected",
            details: {
              manager:,
              manifest:,
              lockfile:,
              frozen_lockfile: true,
              package_manager_version:,
              yarn_generation:
            }.compact
          )
        end

        def evidence
          {
            "package_json" => true,
            "javascript_package_manager" => manager,
            "javascript_lockfile" => lockfile,
            "package_manager_declaration" => package_manager_declaration,
            "package_manager_version" => package_manager_version,
            "package_manager_integrity" => package_manager_integrity,
            "yarn_generation" => yarn_generation
          }.compact
        end
      end

      def call(root:)
        root = Pathname(root)
        manifest = root.join("package.json")
        return unless manifest.file?

        payload = parse_manifest!(manifest)
        lockfile = detect_lockfile!(root)
        manager = SUPPORTED_LOCKFILES.fetch(lockfile)
        raw_declaration = payload["packageManager"]
        declaration = parse_package_manager_declaration!(raw_declaration)
        assert_declaration_matches!(declaration:, manager:, lockfile:)

        Detection.new(
          manager:,
          manifest: "package.json",
          lockfile:,
          package_manager_declaration: raw_declaration,
          package_manager_version: declaration&.version,
          package_manager_integrity: declaration&.integrity,
          yarn_generation: manager == "yarn" ? detect_yarn_generation!(root.join(lockfile)) : nil
        )
      end

      private

      def parse_manifest!(manifest)
        payload = JSON.parse(manifest.read)
        return payload if payload.is_a?(Hash)

        raise Error, "package.json must contain a JSON object"
      rescue JSON::ParserError => error
        raise Error, "Invalid package.json: #{error.message}"
      end

      def detect_lockfile!(root)
        lockfiles = SUPPORTED_LOCKFILES.keys.select { |name| root.join(name).file? }

        if lockfiles.empty?
          supported = SUPPORTED_LOCKFILES.keys.sort.join(", ")
          raise Error,
            "JavaScript package.json requires exactly one supported committed lockfile; " \
            "found none (supported: #{supported})"
        end

        if lockfiles.length > 1
          raise Error,
            "Ambiguous JavaScript package manager: multiple supported lockfiles found: " \
            "#{lockfiles.sort.join(", ")}"
        end

        lockfiles.fetch(0)
      end

      def parse_package_manager_declaration!(raw_declaration)
        return if raw_declaration.nil?

        declaration = raw_declaration.to_s
        manager, separator, version_with_integrity = declaration.partition("@")
        unless separator == "@" && !manager.empty? && !version_with_integrity.empty?
          raise Error,
            "Invalid package.json packageManager #{raw_declaration.inspect}; " \
            "expected <manager>@<exact-version>"
        end

        unless SUPPORTED_MANAGERS.include?(manager)
          raise Error, "Unsupported package.json packageManager #{raw_declaration.inspect}"
        end

        version, integrity = split_version_and_integrity(version_with_integrity)
        unless version.match?(EXACT_VERSION_PATTERN)
          raise Error,
            "package.json packageManager must pin an exact version; " \
            "received #{raw_declaration.inspect}"
        end

        PackageManagerDeclaration.new(manager:, version:, integrity:)
      end

      def split_version_and_integrity(value)
        version, separator, integrity = value.partition("+")
        return [ version, nil ] if separator.empty?

        unless integrity.match?(INTEGRITY_PATTERN)
          raise Error, "Invalid package.json packageManager integrity #{integrity.inspect}"
        end

        [ version, integrity ]
      end

      def detect_yarn_generation!(lockfile)
        contents = lockfile.read
        return "classic" if contents.match?(/^# yarn lockfile v1\s*$/)
        return "berry" if contents.match?(/^__metadata:\s*$/)

        raise Error,
          "Could not determine Yarn generation from yarn.lock; " \
          "expected a Yarn Classic v1 header or Berry __metadata section"
      end

      def assert_declaration_matches!(declaration:, manager:, lockfile:)
        return unless declaration
        return if declaration.manager == manager

        raise Error,
          "package.json packageManager declares #{declaration.manager} but #{lockfile} selects #{manager}"
      end
    end
  end
end
