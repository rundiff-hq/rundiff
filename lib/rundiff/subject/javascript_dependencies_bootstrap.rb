require "digest"
require "pathname"

module RunDiff
  module Subject
    class JavascriptDependenciesBootstrap
      Error = Class.new(StandardError)

      LOCKFILES_BY_MANAGER = {
        "npm" => [ "package-lock.json" ],
        "pnpm" => [ "pnpm-lock.yaml" ],
        "yarn" => [ "yarn.lock" ],
        "bun" => [ "bun.lock", "bun.lockb" ]
      }.freeze

      def initialize(command_runner:)
        @command_runner = command_runner
      end

      def call(root:, step:)
        root = Pathname(root).expand_path
        assert_step_contract!(step)
        manifest = root.join("package.json")
        lockfile_name = step.details.fetch("lockfile")
        lockfile = root.join(lockfile_name)

        raise Error, "JavaScript subject is missing package.json at #{manifest}" unless manifest.file?
        raise Error, "JavaScript subject is missing committed lockfile at #{lockfile}" unless lockfile.file?

        original_manifest_digest = Digest::SHA256.file(manifest).hexdigest
        original_lockfile_digest = Digest::SHA256.file(lockfile).hexdigest

        begin
          run!(command_for(step), chdir: root)
        ensure
          assert_unchanged!(manifest, original_manifest_digest, label: "package.json")
          assert_unchanged!(lockfile, original_lockfile_digest, label: lockfile_name)
        end

        {}
      end

      private

      def assert_step_contract!(step)
        manager = step.details.fetch("manager", nil).to_s
        lockfile = step.details.fetch("lockfile", nil).to_s
        allowed_lockfiles = LOCKFILES_BY_MANAGER[manager]

        raise Error, "Unsupported JavaScript package manager #{manager.inspect}" unless allowed_lockfiles
        return if allowed_lockfiles.include?(lockfile)

        raise Error,
          "JavaScript package manager #{manager} requires one of #{allowed_lockfiles.join(", ")}; " \
          "received #{lockfile.inspect}"
      end

      def command_for(step)
        case step.details.fetch("manager")
        when "npm"
          %w[npm ci]
        when "pnpm"
          %w[pnpm install --frozen-lockfile]
        when "yarn"
          yarn_command(step)
        when "bun"
          %w[bun install --frozen-lockfile]
        end
      end

      def yarn_command(step)
        case step.details.fetch("yarn_generation", nil)
        when "classic"
          %w[yarn install --frozen-lockfile]
        when "berry"
          %w[yarn install --immutable]
        else
          raise Error, "Yarn dependency bootstrap requires deterministic yarn_generation evidence"
        end
      end

      def run!(command, chdir:)
        @command_runner.call(env: {}, command:, chdir: chdir.to_s)
      end

      def assert_unchanged!(path, expected_digest, label:)
        unless path.file?
          raise Error, "JavaScript dependency bootstrap removed committed #{label}"
        end

        actual_digest = Digest::SHA256.file(path).hexdigest
        return if actual_digest == expected_digest

        raise Error, "JavaScript dependency bootstrap mutated committed #{label}"
      end
    end
  end
end
