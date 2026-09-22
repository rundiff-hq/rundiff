#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../lib/rundiff/runtime_diagnosis"
require_relative "../lib/rundiff/async_diagnosis"
require_relative "../lib/rundiff/async_delta_diagnosis"
require_relative "../lib/rundiff/behavioral_diff"
require_relative "../lib/rundiff/execution_reducer"
require_relative "../lib/rundiff/execution_pair"

baseline_path, candidate_path, changed_paths_path, output_path = ARGV
abort "usage: rundiff_compare_captures.rb BASE CANDIDATE CHANGED_PATHS OUTPUT" unless output_path

baseline = RunDiff::ExecutionReducer.call(
  execution: JSON.parse(File.read(baseline_path))
)
candidate = RunDiff::ExecutionReducer.call(
  execution: JSON.parse(File.read(candidate_path))
)
changed_paths = JSON.parse(File.read(changed_paths_path))

pair = RunDiff::ExecutionPair.call(
  baseline:,
  candidate:,
  changed_paths:
)

File.write(output_path, JSON.pretty_generate(pair))
