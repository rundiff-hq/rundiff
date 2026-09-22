CREATE TABLE executions (
  id TEXT PRIMARY KEY,
  review_id TEXT NOT NULL,
  repository TEXT NOT NULL,
  pull_request_number INTEGER NOT NULL,
  scenario_id TEXT NOT NULL,
  baseline_sha TEXT NOT NULL,
  candidate_sha TEXT NOT NULL,
  attempt_number INTEGER NOT NULL,
  status TEXT NOT NULL,
  request_json TEXT NOT NULL,
  result_json TEXT,
  result_digest TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(review_id, attempt_number)
);

CREATE INDEX idx_executions_bridge_match
  ON executions(
    repository,
    pull_request_number,
    baseline_sha,
    candidate_sha,
    status,
    created_at
  );
