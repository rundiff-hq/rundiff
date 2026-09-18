class AddExecutorCancellationState < ActiveRecord::Migration[8.1]
  def change
    add_column :rundiff_executions, :cancelled_at, :datetime
    add_column :rundiff_executions, :cancellation_reason, :string

    add_column :rundiff_executor_requests, :cancelled_at, :datetime
    add_column :rundiff_executor_requests, :cancellation_reason, :string
  end
end
