require "test_helper"
require "tmpdir"

class RunDiffSubjectRailsSetupPlanDetectorTest < ActiveSupport::TestCase
  Configuration = Data.define(:persistence)

  test "detects reproducible Rails bootstrap and database preparation" do
    with_subject do |root|
      write(root, "Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")
      write(root, "Gemfile.lock", "BUNDLED WITH\n   2.6.9\n")
      write(root, "bin/rails", "#!/usr/bin/env ruby\n")
      write(root, "bin/setup", "#!/usr/bin/env ruby\n")
      write(root, ".ruby-version", "3.4.10\n")

      plan = detector.call(
        root:,
        configuration: Configuration.new(persistence: "auto")
      )

      assert_equal "rails", plan.framework
      assert_equal "ruby.bundle", plan.steps_for("bootstrap").sole.operation
      assert_equal "Gemfile.lock", plan.steps_for("bootstrap").sole.details.fetch("lockfile")
      assert_equal "rails.db_prepare", plan.steps_for("prepare").sole.operation
      assert_equal "db:prepare", plan.steps_for("prepare").sole.details.fetch("task")
      assert_equal "auto", plan.steps_for("prepare").sole.details.fetch("persistence_mode")
      assert_equal "subject.state_cleanup", plan.steps_for("cleanup").sole.operation
      assert_equal true, plan.evidence.fetch("bin_setup")
      assert_equal ".ruby-version", plan.evidence.fetch("ruby_version")
    end
  end

  test "composes reproducible JavaScript dependency bootstrap into a Rails plan" do
    with_subject do |root|
      write(root, "Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")
      write(root, "Gemfile.lock", "BUNDLED WITH\n   2.6.9\n")
      write(root, "bin/rails", "#!/usr/bin/env ruby\n")
      write(root, "package.json", <<~JSON)
        {
          "packageManager": "pnpm@10.15.0"
        }
      JSON
      write(root, "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

      plan = detector.call(
        root:,
        configuration: Configuration.new(persistence: "auto")
      )

      bootstrap_steps = plan.steps_for("bootstrap")
      assert_equal [ "ruby.bundle", "javascript.dependencies" ], bootstrap_steps.map(&:operation)
      javascript_step = bootstrap_steps.last
      assert_equal "pnpm", javascript_step.details.fetch("manager")
      assert_equal "pnpm-lock.yaml", javascript_step.details.fetch("lockfile")
      assert_equal true, javascript_step.details.fetch("frozen_lockfile")
      assert_equal "pnpm", plan.evidence.fetch("javascript_package_manager")
      assert_equal "pnpm@10.15.0", plan.evidence.fetch("package_manager_declaration")
    end
  end

  test "fails closed when a Rails package.json is not reproducibly locked" do
    with_subject do |root|
      write(root, "Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")
      write(root, "Gemfile.lock", "BUNDLED WITH\n   2.6.9\n")
      write(root, "bin/rails", "#!/usr/bin/env ruby\n")
      write(root, "package.json", "{}\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(
          root:,
          configuration: Configuration.new(persistence: "auto")
        )
      end

      assert_match(/requires exactly one supported committed lockfile/, error.message)
    end
  end

  test "returns nil when Rails evidence is absent" do
    with_subject do |root|
      write(root, "package.json", "{}\n")

      assert_nil detector.call(
        root:,
        configuration: Configuration.new(persistence: "auto")
      )
    end
  end

  test "fails closed when a Rails subject has no committed lockfile" do
    with_subject do |root|
      write(root, "Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")
      write(root, "bin/rails", "#!/usr/bin/env ruby\n")

      error = assert_raises(RunDiff::Subject::RailsSetupPlanDetector::Error) do
        detector.call(
          root:,
          configuration: Configuration.new(persistence: "auto")
        )
      end

      assert_equal "Rails subject requires a committed Gemfile.lock for reproducible setup", error.message
    end
  end

  private

  def detector
    @detector ||= RunDiff::Subject::RailsSetupPlanDetector.new
  end

  def with_subject
    Dir.mktmpdir("rundiff-setup-plan-") do |directory|
      yield Pathname(directory)
    end
  end

  def write(root, relative_path, content)
    path = root.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end
end
