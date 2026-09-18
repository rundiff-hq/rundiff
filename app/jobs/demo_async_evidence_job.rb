class DemoAsyncEvidenceJob < ApplicationJob
  def perform
    ApplicationRecord.connection.select_value("SELECT 1")
    DemoMailer.notification(Current.rundiff_execution_id).deliver_now
    Net::HTTP.get(URI.parse(RunDiff::Demo::LoopbackHttpServer.url))
    Net::HTTP.get(URI.parse(RunDiff::Demo::LoopbackHttpServer.url))
  end
end
