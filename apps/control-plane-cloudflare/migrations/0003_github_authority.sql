ALTER TABLE executions ADD COLUMN installation_id INTEGER;
ALTER TABLE executions ADD COLUMN github_delivery_id TEXT;
ALTER TABLE executions ADD COLUMN expires_at TEXT;
CREATE TABLE github_deliveries (
  id TEXT PRIMARY KEY,
  digest TEXT NOT NULL,
  review_id TEXT NOT NULL,
  received_at TEXT NOT NULL
);
CREATE TABLE github_pull_requests (
  repository TEXT NOT NULL,
  pull_request_number INTEGER NOT NULL,
  installation_id INTEGER NOT NULL,
  review_id TEXT NOT NULL,
  candidate_sha TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  comment_id INTEGER,
  PRIMARY KEY(repository, pull_request_number)
);
CREATE TABLE github_publications (
  execution_id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'pending',
  check_id INTEGER,
  comment_id INTEGER
);
