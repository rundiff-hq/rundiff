ALTER TABLE executions ADD COLUMN claimed_at TEXT;
ALTER TABLE executions ADD COLUMN heartbeat_at TEXT;
ALTER TABLE executions ADD COLUMN lease_expires_at TEXT;
ALTER TABLE executions ADD COLUMN cancelled_at TEXT;
ALTER TABLE executions ADD COLUMN cancellation_reason TEXT;

CREATE INDEX idx_executions_exact_attempt
  ON executions(id, attempt_number, status, lease_expires_at);
