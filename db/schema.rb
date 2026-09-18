# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_05_004000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "github_webhook_deliveries", force: :cascade do |t|
    t.string "action"
    t.string "base_sha"
    t.datetime "created_at", null: false
    t.string "delivery_id", null: false
    t.string "event", null: false
    t.text "failure"
    t.datetime "finished_at"
    t.string "head_sha"
    t.bigint "installation_id"
    t.integer "pull_request_number"
    t.string "repository"
    t.datetime "started_at"
    t.string "status", default: "accepted", null: false
    t.datetime "updated_at", null: false
    t.string "external_id"
    t.index ["delivery_id"], name: "index_github_webhook_deliveries_on_delivery_id", unique: true
    t.index ["external_id"], name: "index_github_webhook_deliveries_on_external_id"
    t.index ["repository", "pull_request_number"], name: "idx_on_repository_pull_request_number_aa1c3f09bc"
    t.index ["status"], name: "index_github_webhook_deliveries_on_status"
  end

  create_table "rundiff_evidence_events", force: :cascade do |t|
    t.string "confidence"
    t.datetime "created_at", null: false
    t.integer "end_line"
    t.string "execution_id", null: false
    t.datetime "occurred_at", null: false
    t.string "path"
    t.jsonb "payload", default: {}, null: false
    t.string "producer_id"
    t.string "producer_kind", null: false
    t.string "producer_name"
    t.string "run_id"
    t.string "signal", null: false
    t.integer "start_line"
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index ["execution_id", "signal"], name: "index_rundiff_evidence_events_on_execution_id_and_signal"
    t.index ["execution_id"], name: "index_rundiff_evidence_events_on_execution_id"
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
    t.index ["execution_id", "kind", "work_id"], name: "index_rundiff_work_items_on_execution_kind_work", unique: true
    t.index ["execution_id", "status"], name: "index_rundiff_execution_work_items_on_execution_id_and_status"
  end

  create_table "rundiff_executions", force: :cascade do |t|
    t.string "baseline_sha", null: false
    t.string "candidate_sha", null: false
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "decision"
    t.string "execution_id", null: false
    t.text "failure"
    t.datetime "finished_at"
    t.datetime "heartbeat_at"
    t.datetime "lease_expires_at"
    t.jsonb "result", default: {}, null: false
    t.string "scenario_id", null: false
    t.string "source", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.string "outcome"
    t.integer "attempt_count", default: 0, null: false
    t.datetime "cancelled_at"
    t.string "cancellation_reason"
    t.index ["execution_id"], name: "index_rundiff_executions_on_execution_id", unique: true
    t.index ["outcome"], name: "index_rundiff_executions_on_outcome"
    t.index ["status", "lease_expires_at"], name: "index_rundiff_executions_on_status_and_lease_expires_at"
    t.index ["status"], name: "index_rundiff_executions_on_status"
  end

  create_table "rundiff_executor_requests", force: :cascade do |t|
    t.string "claim_token"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "idempotency_key", null: false
    t.datetime "lease_expires_at"
    t.jsonb "request_payload", default: {}, null: false
    t.string "request_digest", null: false
    t.jsonb "result", default: {}, null: false
    t.datetime "started_at"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.datetime "cancelled_at"
    t.string "cancellation_reason"
    t.index ["idempotency_key"], name: "index_rundiff_executor_requests_on_idempotency_key", unique: true
    t.index ["status", "lease_expires_at"], name: "index_rundiff_executor_requests_on_status_and_lease_expires_at"
  end
end
