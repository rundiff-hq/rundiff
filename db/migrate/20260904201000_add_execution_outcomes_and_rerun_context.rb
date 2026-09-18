class AddExecutionOutcomesAndRerunContext < ActiveRecord::Migration[8.1]
  def change
    add_column :rundiff_executions, :outcome, :string
    add_column :rundiff_executions, :attempt_count, :integer, default: 0, null: false
    add_index :rundiff_executions, :outcome

    add_column :github_webhook_deliveries, :external_id, :string
    add_index :github_webhook_deliveries, :external_id
  end
end
