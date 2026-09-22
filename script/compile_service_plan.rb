#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require_relative "../lib/rundiff/subject/configuration"
require_relative "../lib/rundiff/subject/setup_plan"
require_relative "../lib/rundiff/subject/javascript_package_manager_detector"
require_relative "../lib/rundiff/subject/rails_setup_plan_detector"
require_relative "../lib/rundiff/subject/setup_plan_compiler"

root = Pathname(ARGV.fetch(0)).expand_path
configuration = RunDiff::Subject::Configuration.load(root:)
plan = RunDiff::Subject::SetupPlanCompiler.new.call(root:, configuration:)
phases = %w[start_services healthcheck stop_services]

puts JSON.generate(
  "schema_version" => "1",
  "steps" => plan.steps.select { |step| phases.include?(step.phase) }.map(&:to_h)
)
