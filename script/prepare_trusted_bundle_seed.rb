#!/usr/bin/env ruby

require "fileutils"
require "pathname"
require_relative "../lib/rundiff/subject/rails_bundle_bootstrap"

source_root = Pathname(
  ENV.fetch("RUNDIFF_BUNDLE_SEED_SOURCE", ENV.fetch("BUNDLE_PATH", "/usr/local/bundle"))
).expand_path
seed_root = Pathname(
  ENV.fetch("RUNDIFF_BUNDLE_SEED_ROOT", ARGV.fetch(0, "/rundiff-bundle-seed"))
).expand_path
lockfile = Pathname(
  ENV.fetch("RUNDIFF_BUNDLE_SEED_LOCKFILE", File.expand_path("../Gemfile.lock", __dir__))
).expand_path
ruby_version = ENV.fetch("RUNDIFF_BUNDLE_SEED_RUBY_VERSION", RUBY_VERSION)

raise "Bundle seed source does not exist: #{source_root}" unless source_root.directory?
raise "Bundle seed lockfile does not exist: #{lockfile}" unless lockfile.file?
raise "Bundle seed root must not be inside source root" if seed_root.to_s.start_with?("#{source_root}/")

cache_key = RunDiff::Subject::RailsBundleBootstrap.cache_key_for(
  lockfile:,
  ruby_version:
)
destination = seed_root.join(cache_key, "gems")

FileUtils.rm_rf(destination)
FileUtils.mkdir_p(destination)

Dir.children(source_root).sort.each do |entry|
  FileUtils.cp_r(
    source_root.join(entry),
    destination.join(entry),
    preserve: true
  )
end

puts "trusted_bundle_seed=#{cache_key}"
puts "trusted_bundle_seed_source=#{source_root}"
puts "trusted_bundle_seed_destination=#{destination}"
