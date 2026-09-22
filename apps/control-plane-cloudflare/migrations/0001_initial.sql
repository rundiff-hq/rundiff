CREATE TABLE behavioral_reviews (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  scenario_id TEXT NOT NULL,
  baseline_sha TEXT NOT NULL,
  candidate_sha TEXT NOT NULL,
  status TEXT NOT NULL,
  decision TEXT,
  workflow_instance_id TEXT NOT NULL UNIQUE,
  result_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_behavioral_reviews_project_created
  ON behavioral_reviews(project_id, created_at DESC);

CREATE INDEX idx_behavioral_reviews_candidate
  ON behavioral_reviews(project_id, candidate_sha);
