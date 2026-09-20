#!/usr/bin/env ruby

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "json"

request_path = ENV.fetch("RUNDIFF_EXECUTOR_REQUEST_PATH")
result_path = ENV.fetch("RUNDIFF_EXECUTOR_RESULT_PATH")

request = RunDiff::Executor::Request.from_h(JSON.parse(File.read(request_path)))
result = RunDiff::Executor::LocalAdapter.new.call(request:)

File.write(result_path, JSON.pretty_generate(result.to_h))

puts "execution_id=#{request.execution_id}"
puts "attempt_number=#{request.attempt_number}"
puts "result_status=#{result.status}"
puts "result_error_class=#{result.error_class}" if result.error_class
