class ApplicationJob < ActiveJob::Base
  include RunDiff::Rails::ActiveJobExecutionContext
end
