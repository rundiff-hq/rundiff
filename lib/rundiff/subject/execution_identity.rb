require "fileutils"
require "pathname"

module RunDiff
  module Subject
    class ExecutionIdentity
      Error = Class.new(StandardError)

      ENV_UID = "RUNDIFF_SUBJECT_UID".freeze
      ENV_GID = "RUNDIFF_SUBJECT_GID".freeze
      ENV_HOME = "RUNDIFF_SUBJECT_HOME".freeze
      ENV_USER = "RUNDIFF_SUBJECT_USER".freeze

      attr_reader :uid, :gid, :home, :user

      def self.from_env(env = ENV)
        uid = env[ENV_UID]
        gid = env[ENV_GID]
        home = env[ENV_HOME]
        user = env[ENV_USER]

        values = [ uid, gid, home, user ]
        return new if values.all?(&:nil?)

        if values.any?(&:nil?)
          raise Error,
            "Subject execution identity requires #{ENV_UID}, #{ENV_GID}, #{ENV_HOME}, and #{ENV_USER} together"
        end

        new(
          uid: positive_integer!(uid, ENV_UID),
          gid: positive_integer!(gid, ENV_GID),
          home:,
          user:
        )
      end

      def self.positive_integer!(value, key)
        integer = Integer(value, 10)
        raise ArgumentError unless integer.positive?

        integer
      rescue ArgumentError, TypeError
        raise Error, "#{key} must be a positive integer"
      end
      private_class_method :positive_integer!

      def initialize(uid: nil, gid: nil, home: nil, user: nil)
        @uid = uid
        @gid = gid
        @home = home
        @user = user
        @executor_uid = Process.euid
        @executor_gid = Process.egid

        return if disabled?

        if [ uid, gid, home, user ].any?(&:nil?)
          raise Error, "Enabled subject execution identity requires uid, gid, home, and user"
        end
        unless uid.to_i.positive? && gid.to_i.positive?
          raise Error, "Enabled subject execution identity requires positive uid and gid"
        end
        if uid.to_i == @executor_uid
          raise Error, "Subject execution uid must differ from executor uid #{@executor_uid}"
        end
        unless Pathname(home.to_s).absolute?
          raise Error, "Subject execution home must be an absolute path"
        end
        if user.to_s.empty?
          raise Error, "Subject execution user must not be empty"
        end
      end

      def enabled?
        !disabled?
      end

      def spawn_options
        enabled? ? { uid:, gid: } : {}
      end

      def environment(workspace: nil)
        return {} unless enabled?

        {
          "HOME" => workspace ? runtime_home(workspace).to_s : home.to_s,
          "USER" => user.to_s,
          "LOGNAME" => user.to_s
        }
      end

      def prepare_runtime_home(workspace)
        return unless enabled?

        prepare_directory(runtime_home(workspace))
      end

      def runtime_home(workspace)
        Pathname(workspace).expand_path.join("tmp", "rundiff", "home")
      end

      def prepare_parent_directory(path)
        return unless enabled?

        path = Pathname(path)
        FileUtils.mkdir_p(path)
        FileUtils.chown(@executor_uid, @executor_gid, path)
        File.chmod(0o711, path)
      rescue Errno::EPERM, Errno::EACCES => error
        raise Error, "Could not protect executor directory #{path}: #{error.message}"
      end

      def prepare_tree(path)
        return unless enabled?

        path = Pathname(path)
        FileUtils.chown_R(uid, gid, path)
        File.chmod(0o700, path)
      rescue Errno::EPERM, Errno::EACCES => error
        raise Error, "Could not assign subject workspace ownership for #{path}: #{error.message}"
      end

      def seal_tree(path)
        return unless enabled?

        path = Pathname(path)
        FileUtils.chown_R(@executor_uid, @executor_gid, path)
        File.chmod(0o700, path)
      rescue Errno::EPERM, Errno::EACCES => error
        raise Error, "Could not seal subject workspace #{path}: #{error.message}"
      end

      def prepare_directory(path)
        return unless enabled?

        path = Pathname(path)
        FileUtils.mkdir_p(path)
        FileUtils.chown(uid, gid, path)
        File.chmod(0o700, path)
      rescue Errno::EPERM, Errno::EACCES => error
        raise Error, "Could not assign subject directory ownership for #{path}: #{error.message}"
      end

      def prepare_output(path)
        return unless enabled?

        path = Pathname(path)
        FileUtils.mkdir_p(path.dirname)
        File.open(path, "w") { }
        FileUtils.chown(uid, gid, path)
        File.chmod(0o600, path)
      rescue Errno::EPERM, Errno::EACCES => error
        raise Error, "Could not prepare subject output #{path}: #{error.message}"
      end

      def seal_output(path)
        return unless enabled? && Pathname(path).exist?

        path = Pathname(path)
        FileUtils.chown(@executor_uid, @executor_gid, path)
        File.chmod(0o600, path)
      rescue Errno::EPERM, Errno::EACCES => error
        raise Error, "Could not seal subject output #{path}: #{error.message}"
      end

      private

      def disabled?
        uid.nil? && gid.nil? && home.nil? && user.nil?
      end
    end
  end
end
