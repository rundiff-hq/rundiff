#!/usr/bin/env ruby

require "bundler"
require "fileutils"
require "json"
require "openssl"
require "open3"
require "pathname"
require_relative "../lib/rundiff/subject/rails_bundle_bootstrap"

TOOL_ROOT = Pathname(__dir__).join("..").expand_path.freeze
FIXTURE_ROOT = TOOL_ROOT.join("test", "fixtures", "rails_sqlite_subject").freeze
GIT_ROOT = Pathname(ENV.fetch("RUNDIFF_LAB_GIT_ROOT", "/lab-git")).expand_path.freeze
STATE_ROOT = Pathname(ENV.fetch("RUNDIFF_LAB_STATE_ROOT", "/lab-state")).expand_path.freeze
TLS_ROOT = Pathname(ENV.fetch("RUNDIFF_LAB_TLS_ROOT", "/lab-tls")).expand_path.freeze
WORK_ROOT = Pathname(ENV.fetch("RUNDIFF_LAB_WORK_ROOT", "/tmp/rundiff-production-lab")).expand_path.freeze
BUNDLE_SEED_ROOT = Pathname(ENV.fetch("RUNDIFF_LAB_BUNDLE_SEED_ROOT", "/lab-bundle-seed")).expand_path.freeze

module RunDiffProductionLabPrepare
  module_function

  def call
    reset_directories!
    prepare_customer_repository!
    prepare_tls!
    puts "production_lab_prepare=ok"
  end

  def reset_directories!
    FileUtils.rm_rf(WORK_ROOT)
    FileUtils.rm_rf(GIT_ROOT)
    FileUtils.rm_rf(STATE_ROOT)
    FileUtils.rm_rf(TLS_ROOT)
    FileUtils.rm_rf(BUNDLE_SEED_ROOT)
    [ WORK_ROOT, GIT_ROOT, STATE_ROOT, TLS_ROOT, BUNDLE_SEED_ROOT ].each { |path| FileUtils.mkdir_p(path) }
  end

  def prepare_customer_repository!
    work = WORK_ROOT.join("customer-rails")
    FileUtils.mkdir_p(work)
    FileUtils.cp_r("#{FIXTURE_ROOT}/.", work)

    strip_rundiff_runtime(work)
    write_clean_application(work)
    write_clean_application_job(work)
    write_clean_behavior_controller(work)
    write_clean_schema(work)
    work.join(".ruby-version").write("3.4.10\n")
    write_behavior(work, 1)
    create_lockfile(work)
    prepare_bundle_seed!(work)

    run!(%w[git init -q -b main], chdir: work)
    run!([ "git", "config", "user.email", "production-lab@rundiff.local" ], chdir: work)
    run!([ "git", "config", "user.name", "RunDiff Production Lab" ], chdir: work)
    baseline_sha = commit!(work, "Baseline customer behavior")

    run!(%w[git checkout -q -b regression], chdir: work)
    write_behavior(work, 8)
    write_configuration(work)
    regression_sha = commit!(work, "Introduce SQL regression")

    run!(%w[git checkout -q main], chdir: work)
    run!(%w[git checkout -q -b neutral], chdir: work)
    write_configuration(work)
    neutral_sha = commit!(work, "Configure RunDiff without behavior change")

    bare = GIT_ROOT.join("admin", "customer-rails.git")
    FileUtils.mkdir_p(bare.dirname)
    run!([ "git", "clone", "-q", "--bare", work.to_s, bare.to_s ], chdir: WORK_ROOT)
    run!([ "git", "update-ref", "refs/heads/main", baseline_sha ], chdir: bare)
    run!([ "git", "update-ref", "refs/heads/regression", regression_sha ], chdir: bare)
    run!([ "git", "update-ref", "refs/heads/neutral", neutral_sha ], chdir: bare)
    run!([ "git", "update-ref", "refs/pull/1/head", regression_sha ], chdir: bare)
    run!([ "git", "update-ref", "refs/pull/2/head", neutral_sha ], chdir: bare)
    run!(%w[git update-server-info], chdir: bare)

    state = {
      "repository" => "admin/customer-rails",
      "pull_requests" => {
        "1" => { "base_sha" => baseline_sha, "head_sha" => regression_sha, "kind" => "regression" },
        "2" => { "base_sha" => baseline_sha, "head_sha" => neutral_sha, "kind" => "neutral" }
      }
    }
    STATE_ROOT.join("shas.json").write(JSON.pretty_generate(state))

    puts "production_lab_baseline_sha=#{baseline_sha}"
    puts "production_lab_regression_sha=#{regression_sha}"
    puts "production_lab_neutral_sha=#{neutral_sha}"
  end

  def strip_rundiff_runtime(root)
    FileUtils.rm_rf(root.join("lib", "rundiff"))
    FileUtils.rm_f(root.join("app", "models", "current.rb"))
    FileUtils.rm_f(root.join("app", "models", "rundiff_evidence_event.rb"))
    FileUtils.rm_f(root.join("app", "models", "rundiff_execution_work_item.rb"))
    FileUtils.rm_f(root.join("config", "initializers", "runtime_evidence_bridge.rb"))
  end

  def write_clean_application(root)
    root.join("config", "application.rb").write(<<~RUBY)
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
          config.secret_key_base = "rundiff-production-lab-subject"
        end
      end
    RUBY
  end

  def write_clean_application_job(root)
    root.join("app", "jobs", "application_job.rb").write(<<~RUBY)
      class ApplicationJob < ActiveJob::Base
      end
    RUBY
  end

  def write_clean_behavior_controller(root)
    root.join("app", "controllers", "demo", "behavior_controller.rb").write(<<~RUBY)
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

  def write_clean_schema(root)
    root.join("db", "schema.rb").write(<<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_09_05_000001) do
        create_table "widgets", force: :cascade do |t|
          t.datetime "created_at", null: false
          t.string "name"
          t.datetime "updated_at", null: false
        end
      end
    RUBY
  end

  def write_behavior(root, count)
    root.join("config", "behavior_profile.rb").write(<<~RUBY)
      module RailsSqliteSubject
        QUERY_COUNT = #{Integer(count)}
      end
    RUBY
  end

  def write_configuration(root)
    root.join("rundiff.yml").write(<<~YAML)
      version: 1
      scenario:
        path: /__rundiff/demo/behavior
      subject:
        persistence: auto
    YAML
  end

  def create_lockfile(root)
    Bundler.with_unbundled_env do
      run!(%w[bundle lock], chdir: root)
    end
  end

  def prepare_bundle_seed!(root)
    lockfile = root.join("Gemfile.lock")
    cache_key = RunDiff::Subject::RailsBundleBootstrap.cache_key_for(
      lockfile:,
      ruby_version: RUBY_VERSION
    )
    destination = BUNDLE_SEED_ROOT.join(cache_key)
    FileUtils.mkdir_p(destination)

    bundler_version = lockfile.read[/^BUNDLED WITH\n\s+([^\s]+)\s*$/m, 1]
    command = [ "bundle" ]
    command << "_#{bundler_version}_" if bundler_version
    command.concat([ "install", "--jobs", "4", "--retry", "3" ])

    Bundler.with_unbundled_env do
      run!(
        command,
        chdir: root,
        env: {
          "BUNDLE_GEMFILE" => root.join("Gemfile").to_s,
          "BUNDLE_PATH" => destination.join("gems").to_s,
          "BUNDLE_APP_CONFIG" => destination.join("config").to_s,
          "BUNDLE_DEPLOYMENT" => "true",
          "BUNDLE_FROZEN" => "true"
        }
      )
    end

    puts "production_lab_bundle_seed=#{cache_key}"
  end

  def commit!(root, message)
    run!(%w[git add --all], chdir: root)
    run!([ "git", "commit", "-q", "-m", message ], chdir: root)
    run!(%w[git rev-parse HEAD], chdir: root).strip
  end

  def prepare_tls!
    ca_key = OpenSSL::PKey::RSA.new(2048)
    ca_cert = OpenSSL::X509::Certificate.new
    ca_cert.version = 2
    ca_cert.serial = 1
    ca_cert.subject = OpenSSL::X509::Name.parse("/CN=RunDiff Production Lab CA")
    ca_cert.issuer = ca_cert.subject
    ca_cert.public_key = ca_key.public_key
    ca_cert.not_before = Time.now - 60
    ca_cert.not_after = Time.now + (7 * 24 * 60 * 60)

    extension_factory = OpenSSL::X509::ExtensionFactory.new
    extension_factory.subject_certificate = ca_cert
    extension_factory.issuer_certificate = ca_cert
    ca_cert.add_extension(extension_factory.create_extension("basicConstraints", "CA:TRUE", true))
    ca_cert.add_extension(extension_factory.create_extension("keyUsage", "keyCertSign,cRLSign", true))
    ca_cert.add_extension(extension_factory.create_extension("subjectKeyIdentifier", "hash", false))
    ca_cert.sign(ca_key, OpenSSL::Digest::SHA256.new)

    TLS_ROOT.join("ca.pem").write(ca_cert.to_pem)
    TLS_ROOT.join("ca.key").write(ca_key.to_pem)
    File.chmod(0o600, TLS_ROOT.join("ca.key"))

    %w[github-edge control-plane-tls executor-tls].each_with_index do |host, index|
      write_server_certificate!(host:, serial: index + 10, ca_key:, ca_cert:)
    end
  end

  def write_server_certificate!(host:, serial:, ca_key:, ca_cert:)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{host}")
    cert.issuer = ca_cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + (7 * 24 * 60 * 60)

    extension_factory = OpenSSL::X509::ExtensionFactory.new
    extension_factory.subject_certificate = cert
    extension_factory.issuer_certificate = ca_cert
    cert.add_extension(extension_factory.create_extension("basicConstraints", "CA:FALSE", true))
    cert.add_extension(extension_factory.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
    cert.add_extension(extension_factory.create_extension("extendedKeyUsage", "serverAuth", false))
    cert.add_extension(extension_factory.create_extension("subjectAltName", "DNS:#{host}", false))
    cert.sign(ca_key, OpenSSL::Digest::SHA256.new)

    TLS_ROOT.join("#{host}.crt").write(cert.to_pem)
    TLS_ROOT.join("#{host}.key").write(key.to_pem)
    File.chmod(0o600, TLS_ROOT.join("#{host}.key"))
  end

  def run!(command, chdir:, env: {})
    stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir.to_s)
    return stdout if status.success?

    raise "Command failed (#{command.join(" ")}): #{stderr.empty? ? stdout : stderr}"
  end
end

RunDiffProductionLabPrepare.call
