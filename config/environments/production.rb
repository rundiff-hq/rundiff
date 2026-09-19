Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = ENV["RAILS_FORCE_SSL"] == "1"
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [ :request_id ]
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Keep YJIT available by default, but allow memory-constrained executor
  # deployments to prefer interpreter memory usage over JIT throughput.
  config.yjit = false if ENV["RUNDIFF_DISABLE_YJIT"] == "1"
end
