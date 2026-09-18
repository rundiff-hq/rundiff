class CreateRunDiffEvidenceEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :rundiff_evidence_events do |t|
      t.string :execution_id, null: false
      t.string :run_id
      t.string :subject
      t.string :signal, null: false
      t.string :path
      t.integer :start_line
      t.integer :end_line
      t.string :confidence
      t.jsonb :payload, null: false, default: {}
      t.string :producer_kind, null: false
      t.string :producer_name
      t.string :producer_id
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :rundiff_evidence_events, :execution_id
    add_index :rundiff_evidence_events, %i[execution_id signal]
  end
end
