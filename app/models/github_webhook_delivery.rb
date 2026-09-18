class GithubWebhookDelivery < ApplicationRecord
  STATUSES = %w[accepted processing completed ignored failed].freeze
  RUNNABLE_PULL_REQUEST_ACTIONS = %w[opened reopened synchronize ready_for_review].freeze

  validates :delivery_id, :event, :status, presence: true
  validates :delivery_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def pull_request?
    event == "pull_request"
  end

  def runnable_pull_request?
    pull_request? && action.in?(RUNNABLE_PULL_REQUEST_ACTIONS)
  end

  def claim!(now: nil)
    now ||= RunDiff::ClockAuthority.database_now
    claimed = self.class.where(id:, status: "accepted").update_all(
      status: "processing",
      started_at: now,
      finished_at: nil,
      failure: nil,
      updated_at: now
    )

    reload if claimed == 1
    claimed == 1
  end

  def complete!(now: nil)
    update!(status: "completed", finished_at: now || RunDiff::ClockAuthority.database_now, failure: nil)
  end

  def ignore!(reason, now: nil)
    update!(status: "ignored", finished_at: now || RunDiff::ClockAuthority.database_now, failure: reason.to_s)
  end

  def fail!(error, now: nil)
    message = "#{error.class}: #{error.message}".truncate(2_000)
    update!(status: "failed", failure: message, finished_at: now || RunDiff::ClockAuthority.database_now)
  end
end
