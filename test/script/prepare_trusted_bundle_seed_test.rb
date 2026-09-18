require "test_helper"
require "open3"
require "tmpdir"

class PrepareTrustedBundleSeedTest < ActiveSupport::TestCase
  test "copies an immutable source into the exact lock-digest seed layout" do
    Dir.mktmpdir("rundiff-trusted-seed-") do |directory|
      source = Pathname(directory).join("source")
      seed_root = Pathname(directory).join("seed")
      lockfile = Pathname(directory).join("Gemfile.lock")
      source.join("ruby/3.4.0/gems/example-1.0.0").mkpath
      source.join("ruby/3.4.0/gems/example-1.0.0/lib.rb").write("trusted")
      lockfile.write("synthetic lockfile\n")

      stdout, stderr, status = Open3.capture3(
        {
          "RUNDIFF_BUNDLE_SEED_SOURCE" => source.to_s,
          "RUNDIFF_BUNDLE_SEED_ROOT" => seed_root.to_s,
          "RUNDIFF_BUNDLE_SEED_LOCKFILE" => lockfile.to_s,
          "RUNDIFF_BUNDLE_SEED_RUBY_VERSION" => "3.4.10"
        },
        RbConfig.ruby,
        Rails.root.join("script/prepare_trusted_bundle_seed.rb").to_s
      )

      assert status.success?, stderr

      cache_key = RunDiff::Subject::RailsBundleBootstrap.cache_key_for(
        lockfile:,
        ruby_version: "3.4.10"
      )
      copied = seed_root.join(
        cache_key,
        "gems/ruby/3.4.0/gems/example-1.0.0/lib.rb"
      )

      assert_equal "trusted", copied.read
      assert_includes stdout, "trusted_bundle_seed=#{cache_key}"

      copied.write("subject-copy-mutated")

      assert_equal "trusted", source.join("ruby/3.4.0/gems/example-1.0.0/lib.rb").read
      assert_equal "subject-copy-mutated", copied.read
    end
  end

  test "rejects a destination nested inside the trusted source" do
    Dir.mktmpdir("rundiff-trusted-seed-") do |directory|
      source = Pathname(directory).join("source")
      source.mkpath
      lockfile = Pathname(directory).join("Gemfile.lock")
      lockfile.write("synthetic lockfile\n")

      _stdout, stderr, status = Open3.capture3(
        {
          "RUNDIFF_BUNDLE_SEED_SOURCE" => source.to_s,
          "RUNDIFF_BUNDLE_SEED_ROOT" => source.join("seed").to_s,
          "RUNDIFF_BUNDLE_SEED_LOCKFILE" => lockfile.to_s,
          "RUNDIFF_BUNDLE_SEED_RUBY_VERSION" => "3.4.10"
        },
        RbConfig.ruby,
        Rails.root.join("script/prepare_trusted_bundle_seed.rb").to_s
      )

      refute status.success?
      assert_includes stderr, "Bundle seed root must not be inside source root"
    end
  end
end
