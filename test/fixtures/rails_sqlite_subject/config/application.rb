require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

require File.expand_path("../lib/rundiff/execution_context", __dir__)

module RailsSqliteSubject
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: [])
    config.active_job.queue_adapter = :test
    config.middleware.use RunDiff::ExecutionContext
    config.secret_key_base = "rundiff-rails-sqlite-subject-fixture"
  end
end
