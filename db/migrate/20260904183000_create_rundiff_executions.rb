class CreateRunDiffExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :rundiff_executions do |t|
      t.string :execution_id, null: false
      t.string :source, null: false
      t.string :scenario_id, null: false
      t.string :baseline_sha, null: false
      t.string :candidate_sha, null: false
      t.string :status, null: false, default: "queued"
      t.string :decision
      t.jsonb :context, null: false, default: {}
      t.jsonb :result, null: false, default: {}
      t.text :failure
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :rundiff_executions, :execution_id, unique: true
    add_index :rundiff_executions, :status
  end
end
