class AddExecutionLeases < ActiveRecord::Migration[8.1]
  def up
    add_column :rundiff_executions, :heartbeat_at, :datetime
    add_column :rundiff_executions, :lease_expires_at, :datetime
    add_index :rundiff_executions, [ :status, :lease_expires_at ]

    execute <<~SQL.squish
      UPDATE rundiff_executions
      SET heartbeat_at = COALESCE(started_at, updated_at),
          lease_expires_at = COALESCE(started_at, updated_at) + INTERVAL '30 minutes'
      WHERE status = 'running'
    SQL
  end

  def down
    remove_index :rundiff_executions, [ :status, :lease_expires_at ]
    remove_column :rundiff_executions, :lease_expires_at
    remove_column :rundiff_executions, :heartbeat_at
  end
end
