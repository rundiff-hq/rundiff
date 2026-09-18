require_relative "boot"
require_relative "../lib/rundiff/execution_context"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module RunDiffApp
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])
    config.middleware.use RunDiff::ExecutionContext
  end
end
