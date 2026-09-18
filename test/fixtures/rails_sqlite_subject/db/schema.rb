ActiveRecord::Schema[8.1].define(version: 2026_09_05_000001) do
  create_table "rundiff_evidence_events", force: :cascade do |t|
    t.string "confidence"
    t.datetime "created_at", null: false
    t.integer "end_line"
    t.string "execution_id", null: false
    t.datetime "occurred_at", null: false
    t.string "path"
    t.json "payload", default: {}, null: false
    t.string "producer_id"
    t.string "producer_kind", null: false
    t.string "producer_name"
    t.string "run_id"
    t.string "signal", null: false
    t.integer "start_line"
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index [ "execution_id", "signal" ]
  end

  create_table "rundiff_execution_work_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "enqueued_at"
    t.string "error_class"
    t.string "execution_id", null: false
    t.datetime "finished_at"
    t.string "kind", null: false
    t.string "name"
    t.string "queue_name"
    t.string "run_id"
    t.datetime "started_at"
    t.string "status", null: false
    t.string "subject"
    t.datetime "updated_at", null: false
    t.string "work_id", null: false
    t.index [ "execution_id", "kind", "work_id" ], unique: true
    t.index [ "execution_id", "status" ]
  end

  create_table "widgets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end
end
