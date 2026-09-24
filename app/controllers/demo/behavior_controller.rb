module Demo
  class BehaviorController < ApplicationController
    skip_forgery_protection

    PROFILES = {
      "warmup" => { sql_queries: 0, background_jobs: 0, emails: 0, http_requests: 0, delay_ms: 0 },
      "baseline" => { sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 1, delay_ms: 15 },
      "candidate" => { sql_queries: 47, background_jobs: 3, emails: 2, http_requests: 1, delay_ms: 90 },
      "github-pull-request" => { sql_queries: 28, background_jobs: 1, emails: 1, http_requests: 1, delay_ms: 15 }
    }.freeze

    def create
      profile = PROFILES.fetch(Current.rundiff_subject.to_s, PROFILES.fetch("baseline"))

      ApplicationRecord.uncached do
        profile.fetch(:sql_queries).times do
          ApplicationRecord.connection.select_value("SELECT 1")
        end
      end

      profile.fetch(:background_jobs).times do
        DemoNotificationJob.perform_later
      end

      profile.fetch(:emails).times do
        DemoMailer.notification(Current.rundiff_execution_id).deliver_now
      end

      profile.fetch(:http_requests).times do
        Net::HTTP.get(URI.parse(RunDiff::Demo::LoopbackHttpServer.url))
      end

      sleep(profile.fetch(:delay_ms) / 1000.0)

      render json: {
        ok: true,
        run_id: Current.rundiff_run_id,
        execution_id: Current.rundiff_execution_id,
        subject: Current.rundiff_subject
      }
    end
  end
end
