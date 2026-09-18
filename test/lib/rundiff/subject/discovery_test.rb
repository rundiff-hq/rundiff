require "test_helper"
require "tmpdir"

class RunDiffSubjectDiscoveryTest < ActiveSupport::TestCase
  CommandRunner = ->(**) { "" }

  test "discovers Rails PostgreSQL from database configuration" do
    with_rails_subject(database_yml: "default:\n  adapter: postgresql\n") do |root|
      environment = discovery.resolve(root:, configuration: automatic_configuration)

      assert_instance_of RunDiff::Subject::RailsPostgresEnvironment, environment
      assert environment.capability?("persistence.postgresql")
    end
  end

  test "discovers Rails SQLite from database configuration" do
    with_rails_subject(database_yml: "default:\n  adapter: sqlite3\n") do |root|
      environment = discovery.resolve(root:, configuration: automatic_configuration)

      assert_instance_of RunDiff::Subject::RailsSqliteEnvironment, environment
      assert environment.capability?("persistence.sqlite")
    end
  end

  test "uses an explicit supported persistence override" do
    with_rails_subject(database_yml: "") do |root|
      configuration = RunDiff::Subject::Configuration.new(
        scenario_path: nil,
        persistence: "sqlite",
        source_path: nil
      )

      environment = discovery.resolve(root:, configuration:)

      assert_instance_of RunDiff::Subject::RailsSqliteEnvironment, environment
    end
  end

  test "rejects ambiguous Rails database configuration" do
    database_yml = <<~YAML
      development:
        adapter: postgresql
      test:
        adapter: sqlite3
    YAML

    with_rails_subject(database_yml:) do |root|
      error = assert_raises(RunDiff::Subject::Discovery::Error) do
        discovery.resolve(root:, configuration: automatic_configuration)
      end

      assert_match(/Ambiguous Rails persistence/, error.message)
    end
  end

  test "rejects unsupported Rails database adapters" do
    with_rails_subject(database_yml: "default:\n  adapter: mysql2\n") do |root|
      error = assert_raises(RunDiff::Subject::Discovery::Error) do
        discovery.resolve(root:, configuration: automatic_configuration)
      end

      assert_match(/Unsupported Rails database adapter/, error.message)
    end
  end

  test "rejects non Rails subjects explicitly" do
    Dir.mktmpdir do |directory|
      error = assert_raises(RunDiff::Subject::Discovery::Error) do
        discovery.resolve(root: directory, configuration: automatic_configuration)
      end

      assert_match(/expected a Rails application/, error.message)
    end
  end

  private

  def discovery
    @discovery ||= RunDiff::Subject::Discovery.new(command_runner: CommandRunner)
  end

  def automatic_configuration
    RunDiff::Subject::Configuration.new(
      scenario_path: nil,
      persistence: "auto",
      source_path: nil
    )
  end

  def with_rails_subject(database_yml:)
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      FileUtils.mkdir_p(root.join("config"))
      FileUtils.mkdir_p(root.join("bin"))
      root.join("config", "application.rb").write("module CustomerApp; end\n")
      root.join("config", "database.yml").write(database_yml)
      root.join("bin", "rails").write("#!/usr/bin/env ruby\n")
      yield root
    end
  end
end
