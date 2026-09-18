#!/usr/bin/env ruby

require "json"
require "securerandom"

require File.join(Dir.pwd, "config/environment")

class RunDiffDurableWorkerProbeJob < ApplicationJob
  def perform
    ApplicationRecord.connection.select_value("SELECT 1")
    DemoMailer.notification(Current.rundiff_execution_id).deliver_now
    Net::HTTP.get(URI.parse(RunDiff::Demo::LoopbackHttpServer.url))
  end
end

execution_id = SecureRandom.uuid
run_id = "durable-worker-#{SecureRandom.hex(4)}"
serialized_job = nil
origin_collector = RunDiff::Rails::EvidenceCollector.new(execution_id:)

origin_measurements = origin_collector.capture do
  Current.set(
    rundiff_execution_id: execution_id,
    rundiff_run_id: run_id,
    rundiff_subject: "durable-worker-proof"
  ) do
    serialized_job = RunDiffDurableWorkerProbeJob.new.serialize
  end
end

Current.reset
raise "RunDiff execution context leaked after origin lifecycle" if Current.rundiff_execution_id

ActiveJob::Base.deserialize(serialized_job).perform_now

records = RunDiffEvidenceEvent.where(execution_id:).order(:id).to_a
runtime_signals = %w[
  queue_wait_ms
  scheduled_delay_ms
  dispatch_wait_ms
  worker_wall_ms
  worker_process_cpu_ms
  worker_thread_cpu_ms
]
product_records = records.reject { |record| runtime_signals.include?(record.signal) }
runtime_records = records.select { |record| runtime_signals.include?(record.signal) }
expected_product_signals = %w[sql_queries emails http_requests]

unless product_records.map(&:signal) == expected_product_signals
  raise "Expected #{expected_product_signals.inspect}, got #{product_records.map(&:signal).inspect}"
end
raise "Expected worker runtime probes #{runtime_signals.inspect}" unless runtime_records.map(&:signal) == runtime_signals
raise "Expected one producer kind" unless records.all? { |record| record.producer_kind == "active_job" }
raise "Expected probe job producer" unless records.all? { |record| record.producer_name == "RunDiffDurableWorkerProbeJob" }
raise "Expected propagated run id" unless records.all? { |record| record.run_id == run_id }
raise "Expected propagated subject" unless records.all? { |record| record.subject == "durable-worker-proof" }
raise "Expected application source attribution" unless product_records.all? { |record| record.path == "script/rundiff_durable_worker_evidence.rb" }
raise "Expected numeric worker runtime values" unless runtime_records.all? { |record| record.payload.fetch("value").is_a?(Numeric) }

queue_records = runtime_records.first(3)
expected_semantics = %w[enqueue_to_start enqueue_to_eligibility eligibility_to_start]
unless queue_records.map { |record| record.payload.fetch("semantics") } == expected_semantics
  raise "Expected queue stage semantics #{expected_semantics.inspect}"
end

queue_wait = queue_records[0].payload.fetch("value")
scheduled_delay = queue_records[1].payload.fetch("value")
dispatch_wait = queue_records[2].payload.fetch("value")
unless (queue_wait - scheduled_delay - dispatch_wait).abs <= 0.1
  raise "Queue stage decomposition does not add up"
end

payload = {
  execution_id:,
  run_id:,
  origin_collector_closed_before_worker: true,
  origin_measurements:,
  current_cleared_before_worker: true,
  persisted_events: records.map do |record|
    {
      signal: record.signal,
      path: record.path,
      line: record.start_line,
      confidence: record.confidence,
      value: record.payload["value"],
      semantics: record.payload["semantics"],
      producer_kind: record.producer_kind,
      producer_name: record.producer_name,
      producer_id: record.producer_id
    }
  end
}

puts JSON.pretty_generate(payload)
