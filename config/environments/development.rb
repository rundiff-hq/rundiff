require "uri"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true
  config.action_controller.perform_caching = false
  config.active_support.deprecation = :log

  # Quick Cloudflare tunnels use a random *.trycloudflare.com hostname.
  config.hosts << /[a-z0-9-]+\.trycloudflare\.com/

  if ENV["RUNDIFF_PUBLIC_URL"].present?
    public_host = URI(ENV.fetch("RUNDIFF_PUBLIC_URL")).host
    config.hosts << public_host if public_host
  end
end
