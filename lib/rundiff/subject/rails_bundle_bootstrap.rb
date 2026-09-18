require "digest"
require "fileutils"
require "pathname"
require "rbconfig"
require_relative "execution_identity"

module RunDiff
  module Subject
    class RailsBundleBootstrap
      Error = Class.new(StandardError)

      def self.cache_key_for(lockfile:, ruby_version:)
        lock_digest = Digest::SHA256.file(lockfile).hexdigest
        match = ruby_version.to_s.match(/\A(\d+)\.(\d+)/)
        raise Error, "Unsupported Ruby version declaration #{ruby_version.inspect}" unless match

        "ruby-#{match[1]}.#{match[2]}-#{lock_digest[0, 20]}"
      end

      def initialize(
        command_runner:,
        cache_root: ::Rails.root.join("tmp", "rundiff", "bundles"),
        ruby_version: RUBY_VERSION,
        bundler_installer_command_runner: command_runner,
        execution_identity: ExecutionIdentity.new,
        seed_root: nil
      )
        @command_runner = command_runner
        @bundler_installer_command_runner = bundler_installer_command_runner
        @cache_root = cache_root && Pathname(cache_root).expand_path
        @ruby_version = ruby_version.to_s
        @execution_identity = execution_identity
        @seed_root = seed_root && Pathname(seed_root).expand_path
      end

      def call(root:)
        root = Pathname(root).expand_path
        gemfile = root.join("Gemfile")
        lockfile = root.join("Gemfile.lock")

        raise Error, "Rails subject is missing Gemfile at #{gemfile}" unless gemfile.file?
        raise Error, "Rails subject must commit Gemfile.lock for reproducible execution" unless lockfile.file?

        assert_ruby_compatible!(root:, lockfile:)
        cache_key = self.class.cache_key_for(lockfile:, ruby_version: @ruby_version)
        bundle_root = bundle_cache_root(root).join(cache_key)
        seed_hit = hydrate_from_seed!(bundle_root:, cache_key:)
        FileUtils.mkdir_p(bundle_root)
        @execution_identity.prepare_tree(bundle_root)

        env = {
          "BUNDLE_GEMFILE" => gemfile.to_s,
          "BUNDLE_PATH" => bundle_root.join("gems").to_s,
          "BUNDLE_APP_CONFIG" => bundle_root.join("config").to_s,
          "BUNDLE_DEPLOYMENT" => "true",
          "BUNDLE_FROZEN" => "true"
        }

        original_digest = Digest::SHA256.file(lockfile).hexdigest
        bundler_version = bundled_with(lockfile)
        ensure_bundler!(version: bundler_version, chdir: root)
        bundle_command = bundler_command(version: bundler_version)

        begin
          run!(env:, command: bundle_command + [ "check" ], chdir: root)
        rescue RunDiff::Github::LocalPullRequestRunner::Error
          run!(
            env:,
            command: bundle_command + [ "install", "--jobs", "4", "--retry", "3" ],
            chdir: root
          )
        end

        actual_digest = Digest::SHA256.file(lockfile).hexdigest
        if actual_digest != original_digest
          raise Error, "Customer Gemfile.lock changed during dependency bootstrap"
        end

        env.merge(
          "RUNDIFF_SUBJECT_RUBY_VERSION" => requested_ruby_version(root:, lockfile:) || @ruby_version,
          "RUNDIFF_SUBJECT_BUNDLER_VERSION" => bundler_version || "default",
          "RUNDIFF_SUBJECT_BUNDLE_SEED" => seed_hit ? "hit" : "miss"
        )
      end

      private

      def hydrate_from_seed!(bundle_root:, cache_key:)
        return false unless @seed_root

        seed = @seed_root.join(cache_key)
        return false unless seed.directory?

        FileUtils.rm_rf(bundle_root)
        FileUtils.mkdir_p(bundle_root)
        Dir.children(seed).each do |entry|
          FileUtils.cp_r(seed.join(entry), bundle_root.join(entry), preserve: true)
        end
        true
      rescue Errno::EACCES, Errno::EPERM, Errno::ENOENT => error
        raise Error, "Could not hydrate bundle seed #{seed}: #{error.message}"
      end

      def run!(env:, command:, chdir:)
        @command_runner.call(env:, command:, chdir: chdir.to_s)
      end

      def run_installer!(env:, command:, chdir:)
        @bundler_installer_command_runner.call(env:, command:, chdir: chdir.to_s)
      end

      def ensure_bundler!(version:, chdir:)
        return unless version

        begin
          run_installer!(env: {}, command: [ "gem", "list", "-i", "bundler", "-v", version ], chdir:)
        rescue RunDiff::Github::LocalPullRequestRunner::Error
          run_installer!(
            env: {},
            command: [ "gem", "install", "bundler", "-v", version, "--no-document" ],
            chdir:
          )
        end
      end

      def bundler_command(version:)
        command = [ "bundle" ]
        version ? command + [ "_#{version}_" ] : command
      end

      def bundled_with(lockfile)
        contents = lockfile.read
        match = contents.match(/^BUNDLED WITH\n\s+([^\s]+)\s*$/m)
        match && match[1]
      end

      def assert_ruby_compatible!(root:, lockfile:)
        requested = requested_ruby_version(root:, lockfile:)
        return unless requested

        requested_line = major_minor(requested)
        executor_line = major_minor(@ruby_version)
        return if requested_line == executor_line

        raise Error,
          "Rails subject requires Ruby #{requested} but executor provides Ruby #{@ruby_version}; " \
          "v0.1 requires the same Ruby major/minor line"
      end

      def requested_ruby_version(root:, lockfile:)
        ruby_version_file = root.join(".ruby-version")
        if ruby_version_file.file?
          value = ruby_version_file.read.strip.sub(/\Aruby-/, "")
          return value unless value.empty?
        end

        contents = lockfile.read
        match = contents.match(/^RUBY VERSION\n\s+ruby\s+([^\s]+).*$/m)
        match && match[1]
      end

      def major_minor(version)
        match = version.to_s.match(/\A(\d+)\.(\d+)/)
        raise Error, "Unsupported Ruby version declaration #{version.inspect}" unless match

        [ match[1], match[2] ]
      end

      def bundle_cache_root(root)
        @cache_root || root.join("tmp", "rundiff", "bundles")
      end
    end
  end
end
