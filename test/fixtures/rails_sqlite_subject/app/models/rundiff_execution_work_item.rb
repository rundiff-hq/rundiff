class RunDiffExecutionWorkItem < ApplicationRecord
  self.table_name = "rundiff_execution_work_items"
  ACTIVE_STATUSES = %w[enqueued running].freeze
  TERMINAL_STATUSES = %w[completed failed].freeze
  STATUSES = (ACTIVE_STATUSES + TERMINAL_STATUSES).freeze

  validates :execution_id, :kind, :work_id, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :work_id, uniqueness: { scope: %i[execution_id kind] }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
end
