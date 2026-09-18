#!/usr/bin/env ruby

require "bundler"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze
FIXTURE_ROOT = TOOL_ROOT.join("test", "fixtures", "rails_sqlite_subject").freeze
TOOL_LOCKFILE = TOOL_ROOT.join("Gemfile.lock").freeze

ENV["RAILS_ENV"] ||= "test"
require TOOL_ROOT.join("config", "environment").to_s

module RailsSqliteSubjectProof
  class GuardedCommandRunner
    def initialize(delegate:, lockfile:, expected_digest:)
      @delegate = delegate
      @lockfile = lockfile
      @expected_digest = expected_digest
    end

    def call(env:, command:, chdir:)
      verify!(phase: "before", command:, chdir:)
      @delegate.call(env:, command:, chdir:)
    ensure
      verify!(phase: "after", command:, chdir:)
    end

    private

    def verify!(phase:, command:, chdir:)
      actual_digest = Digest::SHA256.file(@lockfile).hexdigest
      return if actual_digest == @expected_digest

      raise RunDiff::Github::LocalPullRequestRunner::Error,
        "Control-plane lockfile was already mutated #{phase} command: #{command.join(" ")} (chdir=#{chdir})"
    end
  end

  module_function

  def call
    Dir.mktmpdir("rundiff-rails-sqlite-subject-") do |directory|
      Dir.mktmpdir("rundiff-rails-sqlite-bootstrap-") do |bootstrap_directory|
        subject_root = Pathname(directory)
        bootstrap_root = Pathname(bootstrap_directory)
        tool_lock_digest = Digest::SHA256.file(TOOL_LOCKFILE).hexdigest

        prepare_subject_repository(subject_root)
        baseline_sha = commit(subject_root, "Baseline clean Rails behavior")
        write_candidate_behavior(subject_root)
        write_candidate_configuration(subject_root)
        candidate_sha = commit(subject_root, "Increase query behavior and configure RunDiff")
        verify_tool_lock_unchanged!(tool_lock_digest)

        request = build_request(baseline_sha:, candidate_sha:)
        command_runner = GuardedCommandRunner.new(
          delegate: RunDiff::Github::LocalPullRequestRunner::CommandRunner.new,
          lockfile: TOOL_LOCKFILE,
          expected_digest: tool_lock_digest
        )
        runtime_capabilities = RunDiff::Subject::RuntimeCapabilities.ruby_only
        ruby_bundle_bootstrap = RunDiff::Subject::RailsBundleBootstrap.new(
          command_runner:,
          cache_root: bootstrap_root
        )
        subject_bootstrap = RunDiff::Subject::BootstrapExecutor.new(
          ruby_bundle_bootstrap:,
          runtime_capabilities:
        )
        runner = RunDiff::Github::LocalPullRequestRunner.new(
          root: subject_root,
          tool_root: TOOL_ROOT,
          command_runner:,
          fetch_repository: false,
          subject_bootstrap:,
          runtime_capabilities:
        )
        result = RunDiff::Executor::LocalAdapter.new(runner:).call(request:)

        verify!(result)
        verify_clean_customer!(subject_root)
        verify_tool_lock_unchanged!(tool_lock_digest)
        print_proof(request:, result:, runtime_capabilities:)
      end
    end
  end

  def prepare_subject_repository(subject_root)
    FileUtils.cp_r("#{FIXTURE_ROOT}/.", subject_root)
    strip_rundiff_runtime(subject_root)
    write_clean_application(subject_root)
    write_clean_application_job(subject_root)
    write_clean_behavior_controller(subject_root)
    write_clean_schema(subject_root)
    create_lockfile(subject_root)

    run!(%w[git init -q], chdir: subject_root)
    run!([ "git", "config", "user.email", "sqlite-proof@rundiff.local" ], chdir: subject_root)
    run!([ "git", "config", "user.name", "RunDiff SQLite Proof" ], chdir: subject_root)
  end

  def strip_rundiff_runtime(subject_root)
    FileUtils.rm_rf(subject_root.join("lib", "rundiff"))
    FileUtils.rm_f(subject_root.join("app", "models", "current.rb"))
    FileUtils.rm_f(subject_root.join("app", "models", "rundiff_evidence_event.rb"))
    FileUtils.rm_f(subject_root.join("app", "models", "rundiff_execution_work_item.rb"))
    FileUtils.rm_f(subject_root.join("config", "initializers", "runtime_evidence_bridge.rb"))
  end

  def write_clean_application(subject_root)
    subject_root.join("config", "application.rb").write(<<~RUBY)
      require_relative "boot"

      require "rails"
      require "active_record/railtie"
      require "active_job/railtie"
      require "action_controller/railtie"

      Bundler.require(*Rails.groups)

      module RailsSqliteSubject
        class Application < Rails::Application
          config.load_defaults 8.1
          config.active_job.queue_adapter = :test
          config.secret_key_base = "rundiff-rails-sqlite-subject-fixture"
        end
      end
    RUBY
  end

  def write_clean_application_job(subject_root)
    subject_root.join("app", "jobs", "application_job.rb").write(<<~RUBY)
      class ApplicationJob < ActiveJob::Base
      end
    RUBY
  end

  def write_clean_behavior_controller(subject_root)
    subject_root.join("app", "controllers", "demo", "behavior_controller.rb").write(<<~RUBY)
      require Rails.root.join("config/behavior_profile").to_s

      module Demo
        class BehaviorController < ApplicationController
          skip_forgery_protection

          def create
            ApplicationRecord.uncached do
              RailsSqliteSubject::QUERY_COUNT.times do
                Widget.where(id: -1).load
              end
            end

            DemoJob.perform_later
            render json: { ok: true }
          end
        end
      end
    RUBY
  end

  def write_clean_schema(subject_root)
    subject_root.join("db", "schema.rb").write(<<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_09_05_000001) do
        create_table "widgets", force: :cascade do |t|
          t.datetime "created_at", null: false
          t.string "name"
          t.datetime "updated_at", null: false
        end
      end
    RUBY
  end

  def create_lockfile(subject_root)
    Bundler.with_unbundled_env do
      run!(%w[bundle lock], chdir: subject_root)
    end
  end

  def commit(subject_root, message)
    run!(%w[git add --all], chdir: subject_root)
    run!([ "git", "commit", "-q", "-m", message ], chdir: subject_root)
    run!(%w[git rev-parse HEAD], chdir: subject_root).strip
  end

  def write_candidate_behavior(subject_root)
    subject_root.join("config", "behavior_profile.rb").write(<<~RUBY)
      module RailsSqliteSubject
        QUERY_COUNT = 8
      end
    RUBY
  end

  def write_candidate_configuration(subject_root)
    subject_root.join("rundiff.yml").write(<<~YAML)
      version: 1
      scenario:
        path: /__rundiff/demo/behavior
      subject:
        persistence: auto
    YAML
  end

  def build_request(baseline_sha:, candidate_sha:)
    RunDiff::Executor::Request.new(
      schema_version: RunDiff::Executor::Request.current_schema_version,
      execution_id: "github-sqlite-proof-001",
      scenario_id: "rails.sqlite.query-behavior",
      baseline_sha:,
      candidate_sha:,
      attempt_number: 1,
      context: {
        "repository" => "fixture/rails-sqlite-subject",
        "candidate_repository" => "fixture/rails-sqlite-subject",
        "pull_request_number" => 1,
        "baseline_ref" => "main",
        "candidate_ref" => "candidate"
      }
    )
  end

  def verify!(result)
    raise "SQLite subject execution failed: #{result.error_class}: #{result.error_message}" unless result.success?

    payload = result.payload
    baseline = payload.dig("executions", "baseline")
    candidate = payload.dig("executions", "candidate")
    baseline_queries = baseline.dig("measurements", "sql_queries")
    candidate_queries = candidate.dig("measurements", "sql_queries")
    finding = payload.dig("result", "findings")&.find do |item|
      item["reason_code"] == "DATABASE_QUERY_REGRESSION"
    end

    raise "Expected portable tool-owned capture for baseline" unless baseline.dig("lifecycle", "capture_runtime") == "tool_owned_portable_rails"
    raise "Expected portable tool-owned capture for candidate" unless candidate.dig("lifecycle", "capture_runtime") == "tool_owned_portable_rails"
    raise "SQLite baseline query evidence is missing" unless baseline_queries.is_a?(Numeric)
    raise "SQLite candidate query evidence is missing" unless candidate_queries.is_a?(Numeric)
    raise "Expected candidate SQLite query count to exceed baseline" unless candidate_queries > baseline_queries
    raise "Expected DATABASE_QUERY_REGRESSION from SQLite subject" unless finding
  end

  def verify_clean_customer!(subject_root)
    forbidden = [
      subject_root.join("lib", "rundiff"),
      subject_root.join("app", "models", "current.rb"),
      subject_root.join("app", "models", "rundiff_evidence_event.rb"),
      subject_root.join("app", "models", "rundiff_execution_work_item.rb"),
      subject_root.join("config", "initializers", "runtime_evidence_bridge.rb")
    ]
    present = forbidden.select(&:exist?)
    return if present.empty?

    raise "Customer fixture still owns RunDiff runtime files: #{present.join(", ")}"
  end

  def verify_tool_lock_unchanged!(expected_digest)
    actual_digest = Digest::SHA256.file(TOOL_LOCKFILE).hexdigest
    return if actual_digest == expected_digest

    raise "SQLite subject dependency setup mutated the RunDiff control-plane lockfile"
  end

  def print_proof(request:, result:, runtime_capabilities:)
    payload = result.payload
    puts "Arbitrary Rails + SQLite customer bootstrap proof"
    puts "request_schema=#{request.schema_version}"
    puts "result_schema=#{result.schema_version}"
    puts "result_status=#{result.status}"
    puts "baseline_sql_queries=#{payload.dig("executions", "baseline", "measurements", "sql_queries")}"
    puts "candidate_sql_queries=#{payload.dig("executions", "candidate", "measurements", "sql_queries")}"
    puts "reason_code=DATABASE_QUERY_REGRESSION"
    puts "merge_recommendation=#{payload.dig("result", "merge_recommendation")}"
    puts "candidate_config_applied_to_baseline=true"
    puts "subject_persistence_discovered=sqlite"
    puts "dependency_bootstrap=typed_setup_plan"
    puts "executor_ruby_capability=#{runtime_capabilities.runtime_version("ruby")}"
    puts "capture_runtime=tool_owned_portable_rails"
    puts "customer_rundiff_runtime_files=false"
    puts "customer_controller_knows_rundiff=false"
    puts "control_plane_lockfile_unchanged=true"
  end

  def run!(command, chdir:, env: {})
    stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir.to_s)
    return stdout if status.success?

    raise "Command failed (#{command.join(" ")}): #{stderr.presence || stdout}"
  end
end

RailsSqliteSubjectProof.call
