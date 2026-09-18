require "test_helper"
require "tmpdir"

class RunDiffSubjectJavascriptPackageManagerDetectorTest < ActiveSupport::TestCase
  test "detects the package manager from exactly one supported lockfile" do
    {
      "package-lock.json" => "npm",
      "pnpm-lock.yaml" => "pnpm",
      "yarn.lock" => "yarn",
      "bun.lock" => "bun",
      "bun.lockb" => "bun"
    }.each do |lockfile, manager|
      with_subject do |root|
        write(root, "package.json", "{}\n")
        write(root, lockfile, lockfile == "yarn.lock" ? "# yarn lockfile v1\n" : "lock\n")

        detection = detector.call(root:)

        assert_equal manager, detection.manager
        assert_equal "package.json", detection.manifest
        assert_equal lockfile, detection.lockfile
        assert_equal "javascript.dependencies", detection.bootstrap_step.operation
        assert_equal true, detection.bootstrap_step.details.fetch("frozen_lockfile")
        assert_equal manager, detection.evidence.fetch("javascript_package_manager")
        if manager == "yarn"
          assert_equal "classic", detection.bootstrap_step.details.fetch("yarn_generation")
        end
      end
    end
  end

  test "detects Yarn Berry from lockfile metadata" do
    with_subject do |root|
      write(root, "package.json", "{}\n")
      write(root, "yarn.lock", <<~LOCK)
        __metadata:
          version: 8
          cacheKey: 10c0
      LOCK

      detection = detector.call(root:)

      assert_equal "yarn", detection.manager
      assert_equal "berry", detection.yarn_generation
      assert_equal "berry", detection.bootstrap_step.details.fetch("yarn_generation")
      assert_equal "berry", detection.evidence.fetch("yarn_generation")
    end
  end

  test "fails closed when Yarn generation cannot be determined" do
    with_subject do |root|
      write(root, "package.json", "{}\n")
      write(root, "yarn.lock", "unrecognized\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(root:)
      end

      assert_match(/Could not determine Yarn generation/, error.message)
    end
  end

  test "returns nil when package.json is absent" do
    with_subject do |root|
      write(root, "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

      assert_nil detector.call(root:)
    end
  end

  test "fails closed when package.json has no supported committed lockfile" do
    with_subject do |root|
      write(root, "package.json", "{}\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(root:)
      end

      assert_match(/requires exactly one supported committed lockfile/, error.message)
    end
  end

  test "fails closed when multiple supported lockfiles are present" do
    with_subject do |root|
      write(root, "package.json", "{}\n")
      write(root, "package-lock.json", "{}\n")
      write(root, "yarn.lock", "# yarn lockfile v1\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(root:)
      end

      assert_equal(
        "Ambiguous JavaScript package manager: multiple supported lockfiles found: package-lock.json, yarn.lock",
        error.message
      )
    end
  end

  test "parses exact packageManager version into evidence and bootstrap step" do
    with_subject do |root|
      write(root, "package.json", <<~JSON)
        {
          "packageManager": "pnpm@10.15.0"
        }
      JSON
      write(root, "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

      detection = detector.call(root:)

      assert_equal "pnpm", detection.manager
      assert_equal "pnpm@10.15.0", detection.evidence.fetch("package_manager_declaration")
      assert_equal "10.15.0", detection.evidence.fetch("package_manager_version")
      assert_equal "10.15.0", detection.bootstrap_step.details.fetch("package_manager_version")
      assert_nil detection.package_manager_integrity
    end
  end

  test "parses Corepack integrity without changing the requested package-manager version" do
    with_subject do |root|
      write(root, "package.json", <<~JSON)
        {
          "packageManager": "pnpm@10.15.0+sha512.aBcD0123"
        }
      JSON
      write(root, "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

      detection = detector.call(root:)

      assert_equal "10.15.0", detection.package_manager_version
      assert_equal "sha512.aBcD0123", detection.package_manager_integrity
      assert_equal "sha512.aBcD0123", detection.evidence.fetch("package_manager_integrity")
      assert_equal "10.15.0", detection.bootstrap_step.details.fetch("package_manager_version")
    end
  end

  test "fails closed when packageManager does not pin an exact version" do
    [ "pnpm@latest", "pnpm@^10.15.0", "pnpm@10" ].each do |declaration|
      with_subject do |root|
        write(root, "package.json", JSON.generate("packageManager" => declaration))
        write(root, "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

        error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
          detector.call(root:)
        end

        assert_match(/must pin an exact version/, error.message)
      end
    end
  end

  test "fails closed when packageManager integrity is invalid" do
    with_subject do |root|
      write(root, "package.json", JSON.generate("packageManager" => "pnpm@10.15.0+sha512.not-hex"))
      write(root, "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(root:)
      end

      assert_match(/Invalid package.json packageManager integrity/, error.message)
    end
  end

  test "fails closed when packageManager contradicts the committed lockfile" do
    with_subject do |root|
      write(root, "package.json", <<~JSON)
        {
          "packageManager": "pnpm@10.15.0"
        }
      JSON
      write(root, "package-lock.json", "{}\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(root:)
      end

      assert_equal(
        "package.json packageManager declares pnpm but package-lock.json selects npm",
        error.message
      )
    end
  end

  test "rejects invalid package.json instead of guessing" do
    with_subject do |root|
      write(root, "package.json", "{\n")
      write(root, "package-lock.json", "{}\n")

      error = assert_raises(RunDiff::Subject::JavascriptPackageManagerDetector::Error) do
        detector.call(root:)
      end

      assert_match(/Invalid package.json/, error.message)
    end
  end

  private

  def detector
    @detector ||= RunDiff::Subject::JavascriptPackageManagerDetector.new
  end

  def with_subject
    Dir.mktmpdir("rundiff-js-package-manager-") do |directory|
      yield Pathname(directory)
    end
  end

  def write(root, relative_path, content)
    path = root.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end
end
