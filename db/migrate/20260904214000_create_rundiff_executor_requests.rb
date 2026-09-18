class CreateRunDiffExecutorRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :rundiff_executor_requests do |t|
      t.string :idempotency_key, null: false
      t.string :request_digest, null: false
      t.string :status, null: false, default: "processing"
      t.string :claim_token
      t.jsonb :request_payload, null: false, default: {}
      t.jsonb :result, null: false, default: {}
      t.datetime :started_at
      t.datetime :lease_expires_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :rundiff_executor_requests, :idempotency_key, unique: true
    add_index :rundiff_executor_requests, [ :status, :lease_expires_at ]
  end
end
