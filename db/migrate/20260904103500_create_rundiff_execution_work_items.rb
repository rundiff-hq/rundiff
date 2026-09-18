class CreateRunDiffExecutionWorkItems < ActiveRecord::Migration[8.1]
  def change
    create_table :rundiff_execution_work_items do |t|
      t.string :execution_id, null: false
      t.string :run_id
      t.string :subject
      t.string :kind, null: false
      t.string :work_id, null: false
      t.string :name
      t.string :queue_name
      t.string :status, null: false
      t.datetime :enqueued_at
      t.datetime :started_at
      t.datetime :finished_at
      t.string :error_class
      t.timestamps
    end

    add_index :rundiff_execution_work_items,
      %i[execution_id kind work_id],
      unique: true,
      name: "index_rundiff_work_items_on_execution_kind_work"
    add_index :rundiff_execution_work_items, %i[execution_id status]
  end
end
