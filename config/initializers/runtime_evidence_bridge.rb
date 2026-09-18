require Rails.root.join("lib/rundiff/rails/evidence").to_s
require Rails.root.join("lib/rundiff/rails/source_locator").to_s
require Rails.root.join("lib/rundiff/rails/durable_evidence_buffer").to_s
require Rails.root.join("lib/rundiff/rails/net_http_instrumentation").to_s
require Rails.root.join("lib/rundiff/rails/runtime_evidence_bridge").to_s

RunDiff::Rails::RuntimeEvidenceBridge.install!
