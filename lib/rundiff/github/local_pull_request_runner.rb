require "bundler"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../subject/execution_identity"

module RunDiff
  module Github
    class LocalPullRequestRunner
      Error = Class.new(StandardError)

      class CommandRunner
        SAFE_INHERITED_ENV_KEYS = %w[
          PATH
          HOME
          TMPDIR
          LANG
          LC_ALL
          LC_CTYPE
          SSL_CERT_FILE
          SSL_CERT_DIR
        ].freeze

        def initialize(host_env: ENV, execution_identity: RunDiff::Subject::ExecutionIdentity.new)
          @host_env = host_env
          @execution_identity = execution_identity
        end

        def call(env:, command:, chdir:)
          stdout = stderr = status = nil
          child_env = nil
          @execution_identity.prepare_runtime_home(chdir)

          Bundler.with_unbundled_env do
            child_env = safe_inherited_environment
              .merge(env.transform_keys(&:to_s))
              .merge(@execution_identity.environment(workspace: chdir))
            stdout, stderr, status = Open3.capture3(
              child_env,
              *command,
              chdir:,
              unsetenv_others: true,
              **@execution_identity.spawn_options
            )
          end

          return stdout if status.success?

          effective_env_keys = child_env.filter_map { |key, value| key if value }.sort
          output = stderr.presence || stdout
          raise Error,
            "Command failed (#{command.join(" ")}): #{output}\n" \
            "Effective environment keys: #{effective_env_keys.join(", ")}"
        end

        private

        def safe_inherited_environment
          SAFE_INHERITED_ENV_KEYS.each_with_object({}) do |key, environment|
            value = @host_env[key]
            environment[key] = value if value
          end
        end
      end

      def initialize(
        root: Rails.root,
        tool_root: root,
        command_runner: CommandRunner.new,
        fetch_repository: true,
        subject_environment: nil,
        subject_discovery: nil,
        subject_bootstrap: nil,
        subject_lifecycle: nil,
        setup_plan_compiler: nil,
        capture_runtime: nil,
        runtime_capabilities: nil,
        execution_identity: nil,
        subject_command_runner: nil,
        service_executor: nil,
        stage_timer: RunDiff::ExecutionStageTimer.new
      )
        @root = Pathname(root).expand_path
        @tool_root = Pathname(tool_root).expand_path
        @stage_timer = stage_timer
        @command_runner = command_runner
        @fetch_repository = fetch_repository
        @execution_identity = execution_identity || RunDiff::Subject::ExecutionIdentity.from_env
        @subject_command_runner = subject_command_runner || default_subject_command_runner(command_runner)
        runtime_capabilities ||= RunDiff::Subject::RuntimeCapabilities.from_env
        subject_discovery ||= RunDiff::Subject::Discovery.new(
          command_runner: @subject_command_runner,
          execution_identity: @execution_identity
        )
        setup_plan_compiler ||= RunDiff::Subject::SetupPlanCompiler.new(runtime_capabilities:)
        subject_bootstrap ||= default_subject_bootstrap(runtime_capabilities:)
        service_executor ||= RunDiff::Subject::ServiceExecutor.new(execution_identity: @execution_identity)
        @subject_lifecycle = subject_lifecycle || RunDiff::Subject::Lifecycle.new(
          discovery: subject_discovery,
          bootstrap: subject_bootstrap,
          environment: subject_environment,
          setup_plan_compiler:,
          service_executor:,
          stage_timer:
        )
        @capture_runtime = capture_runtime || RunDiff::Subject::RailsCaptureRuntime.new
      end

      def call(execution:)
        context = execution.context
        assert_local_subject!(context:)

        paths = timed(execution:, stage: "prepare") do
          execution_paths(execution:)
        end

        if prepared_workspace?
          verify_prepared_worktree!(
            path: paths.fetch(:baseline_root),
            sha: execution.baseline_sha
          )
          verify_prepared_worktree!(
            path: paths.fetch(:candidate_root),
            sha: execution.candidate_sha
          )
        else
          timed(execution:, stage: "clone") do
            fetch_repository! if @fetch_repository
            assert_commit!(execution.baseline_sha)
            assert_commit!(execution.candidate_sha)
            prepare_worktree!(
              path: paths.fetch(:baseline_root),
              sha: execution.baseline_sha
            )
            prepare_worktree!(
              path: paths.fetch(:candidate_root),
              sha: execution.candidate_sha
            )
          end
        end

        capture_configuration = RunDiff::Subject::Configuration.load(root: paths.fetch(:candidate_root))
        baseline_setup_configuration = RunDiff::Subject::Configuration.load(root: paths.fetch(:baseline_root))

        with_subject_workspace(
          root: paths.fetch(:baseline_root),
          output: paths.fetch(:baseline_output)
        ) do
          @subject_lifecycle.open(
            root: paths.fetch(:baseline_root),
            execution:,
            role: "base",
            configuration: capture_configuration,
            setup_configuration: baseline_setup_configuration
          ) do |baseline_subject|
            capture_subject!(
              execution:,
              root: paths.fetch(:baseline_root),
              label: context.fetch("baseline_ref"),
              sha: execution.baseline_sha,
              environment: baseline_subject.env,
              output: paths.fetch(:baseline_output)
            )
          end
        end

        with_subject_workspace(
          root: paths.fetch(:candidate_root),
          output: paths.fetch(:candidate_output)
        ) do
          @subject_lifecycle.open(
            root: paths.fetch(:candidate_root),
            execution:,
            role: "candidate",
            configuration: capture_configuration,
            setup_configuration: capture_configuration
          ) do |candidate_subject|
            capture_subject!(
              execution:,
              root: paths.fetch(:candidate_root),
              label: context.fetch("candidate_ref"),
              sha: execution.candidate_sha,
              environment: candidate_subject.env,
              output: paths.fetch(:candidate_output)
            )
          end
        end

        compare(
          baseline_output: paths.fetch(:baseline_output),
          candidate_output: paths.fetch(:candidate_output),
          changed_paths: changed_paths(execution:)
        )
      ensure
        unless prepared_workspace?
          cleanup_worktree(paths&.fetch(:baseline_root, nil))
          cleanup_worktree(paths&.fetch(:candidate_root, nil))
        end
      end

      private

      def default_subject_command_runner(command_runner)
        return command_runner unless @execution_identity.enabled?

        CommandRunner.new(execution_identity: @execution_identity)
      end

      def default_subject_bootstrap(runtime_capabilities:)
        cache_root = @execution_identity.enabled? ? nil : @tool_root.join("tmp", "rundiff", "bundles")

        RunDiff::Subject::BootstrapExecutor.new(
          ruby_bundle_bootstrap: RunDiff::Subject::RailsBundleBootstrap.new(
            command_runner: @subject_command_runner,
            bundler_installer_command_runner: @command_runner,
            cache_root:,
            execution_identity: @execution_identity,
            seed_root: ENV["RUNDIFF_SUBJECT_BUNDLE_SEED_ROOT"]
          ),
          javascript_dependencies_bootstrap: RunDiff::Subject::JavascriptDependenciesBootstrap.new(
            command_runner: @subject_command_runner
          ),
          runtime_capabilities:
        )
      end

      def assert_local_subject!(context:)
        candidate_repository = context.fetch("candidate_repository")
        repository = context.fetch("repository")
        return if candidate_repository == repository

        raise Error, "Local GitHub runner only supports same-repository pull requests"
      end

      def fetch_repository!
        run!(command: %w[git fetch --prune origin], chdir: @root)
      end

      def assert_commit!(sha)
        run!(command: [ "git", "cat-file", "-e", "#{sha}^{commit}" ], chdir: @root)
      end

      def execution_paths(execution:)
        if prepared_workspace?
          directory = Pathname(ENV.fetch("RUNDIFF_PREPARED_WORKSPACE_ROOT")).expand_path
          baseline_root = Pathname(ENV.fetch("RUNDIFF_PREPARED_BASELINE_ROOT")).expand_path
          candidate_root = Pathname(ENV.fetch("RUNDIFF_PREPARED_CANDIDATE_ROOT")).expand_path
          return {
            baseline_root:,
            candidate_root:,
            baseline_output: directory.join("base.json"),
            candidate_output: directory.join("candidate.json")
          }
        end

        directory = @root.join("tmp", "rundiff", "github", execution.execution_id.delete_prefix("github-")[0, 16])
        FileUtils.mkdir_p(directory)
        @execution_identity.prepare_parent_directory(directory)

        {
          baseline_root: directory.join("base"),
          candidate_root: directory.join("candidate"),
          baseline_output: directory.join("base.json"),
          candidate_output: directory.join("candidate.json")
        }
      end

      def prepared_workspace?
        ENV["RUNDIFF_PREPARED_BY"] == "go" &&
          ENV["RUNDIFF_PREPARED_WORKSPACE_ROOT"].present? &&
          ENV["RUNDIFF_PREPARED_BASELINE_ROOT"].present? &&
          ENV["RUNDIFF_PREPARED_CANDIDATE_ROOT"].present?
      end

      def verify_prepared_worktree!(path:, sha:)
        raise Error, "Prepared worktree is missing: #{path}" unless path.directory?

        head = run!(command: %w[git rev-parse HEAD], chdir: path).strip
        return if head == sha

        raise Error, "Prepared worktree revision mismatch for #{path}"
      end

      def prepare_worktree!(path:, sha:)
        cleanup_worktree(path)
        FileUtils.rm_rf(path)
        run!(command: [ "git", "worktree", "add", "--detach", path.to_s, sha ], chdir: @root)
        @execution_identity.seal_tree(path)
      end

      def with_subject_workspace(root:, output:)
        @execution_identity.prepare_tree(root)
        @execution_identity.prepare_output(output)
        yield
      ensure
        @execution_identity.seal_output(output) if output
        @execution_identity.seal_tree(root) if root&.exist?
      end

      def capture_subject!(execution:, root:, label:, sha:, environment:, output:)
        capture_script = @capture_runtime.script_for(root:, tool_root: @tool_root)
        env = environment.merge(
          "RUNDIFF_RUN_ID" => execution.execution_id,
          "RUNDIFF_SCENARIO_ID" => execution.scenario_id,
          "RUNDIFF_SUBJECT" => "github-pull-request",
          "RUNDIFF_EXECUTION_LABEL" => label,
          "RUNDIFF_EXECUTION_SHA" => sha,
          "RUNDIFF_OUTPUT" => output.to_s,
          "RUNDIFF_CAPTURE_RUNTIME" => @capture_runtime.mode_for(root:)
        )

        @subject_command_runner.call(
          env:,
          command: [ RbConfig.ruby, capture_script.to_s ],
          chdir: root.to_s
        )
      end

      def changed_paths(execution:)
        output = run!(
          command: [ "git", "diff", "--name-only", "#{execution.baseline_sha}...#{execution.candidate_sha}" ],
          chdir: @root
        )
        output.lines(chomp: true).reject(&:empty?)
      end

      def compare(baseline_output:, candidate_output:, changed_paths:)
        baseline = RunDiff::ExecutionReducer.call(execution: JSON.parse(File.read(baseline_output)))
        candidate = RunDiff::ExecutionReducer.call(execution: JSON.parse(File.read(candidate_output)))
        RunDiff::ExecutionPair.call(baseline:, candidate:, changed_paths:)
      end

      def cleanup_worktree(path)
        return unless path

        run!(
          command: [ "git", "worktree", "remove", "--force", path.to_s ],
          chdir: @root,
          allow_failure: true
        )
        FileUtils.rm_rf(path)
        run!(command: %w[git worktree prune], chdir: @root, allow_failure: true)
      end

      def timed(execution:, stage:, role: nil, &block)
        return yield unless @stage_timer

        @stage_timer.measure(
          execution_id: execution.execution_id,
          stage:,
          role:,
          implementation: "ruby",
          &block
        )
      end

      def run!(command:, chdir:, env: {}, allow_failure: false)
        @command_runner.call(env:, command:, chdir: chdir.to_s)
      rescue Error
        raise unless allow_failure

        ""
      end
    end
  end
end
