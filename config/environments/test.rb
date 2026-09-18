Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false

  if ENV["RUNDIFF_SOLID_QUEUE"] == "1"
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }
    config.solid_queue.logger = ActiveSupport::Logger.new($stdout)
  else
    config.active_job.queue_adapter = :test
  end

  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = true
  config.active_support.deprecation = :stderr
end
