#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"
COMPOSE=(docker compose -f "$ROOT/lab/production/docker-compose.yml")

mkdir -p "$ARTIFACT_DIR"

dump_failure_state() {
  echo "=== production lab container state ===" >&2
  "${COMPOSE[@]}" ps -a || true

  echo "=== production lab control-plane state ===" >&2
  "${COMPOSE[@]}" exec -T control-plane bin/rails runner '
    deliveries = GithubWebhookDelivery.order(:id).map do |delivery|
      {
        delivery_id: delivery.delivery_id,
        event: delivery.event,
        action: delivery.action,
        repository: delivery.repository,
        pull_request_number: delivery.pull_request_number,
        installation_id: delivery.installation_id,
        status: delivery.status,
        failure: delivery.failure&.gsub(/Bearer\s+\S+/i, "Bearer [REDACTED]")
      }
    end
    executions = RunDiffExecution.order(:id).map do |execution|
      {
        execution_id: execution.execution_id,
        status: execution.status,
        outcome: execution.outcome,
        decision: execution.decision,
        failure: execution.failure&.gsub(/Bearer\s+\S+/i, "Bearer [REDACTED]")
      }
    end
    failed_queue_errors = SolidQueue::FailedExecution.order(:id).pluck(:error).map do |error|
      error&.gsub(/Bearer\s+\S+/i, "Bearer [REDACTED]")
    end
    queue = {
      jobs: SolidQueue::Job.count,
      ready: SolidQueue::ReadyExecution.count,
      claimed: SolidQueue::ClaimedExecution.count,
      failed: SolidQueue::FailedExecution.count,
      failed_errors: failed_queue_errors
    }

    puts "production_lab_deliveries=#{deliveries.to_json}"
    puts "production_lab_executions=#{executions.to_json}"
    puts "production_lab_queue=#{queue.to_json}"
  ' || true

  echo "=== production lab application log ===" >&2
  "${COMPOSE[@]}" exec -T control-plane sh -lc '
    if [ -f log/production.log ]; then
      grep -E "RunDiff|GithubPullRequest|GithubWebhook|SolidQueue|ERROR|Error|exception|Exception" log/production.log | tail -n 240
    fi
  ' || true
}

capture_artifacts() {
  "${COMPOSE[@]}" ps -a > "$ARTIFACT_DIR/compose-ps.txt" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color > "$ARTIFACT_DIR/compose.log" 2>&1 || true
}

cleanup() {
  local exit_code=$?

  capture_artifacts

  if [[ $exit_code -ne 0 ]]; then
    dump_failure_state
    echo "=== production lab logs ===" >&2
    cat "$ARTIFACT_DIR/compose.log" >&2 || true
  fi

  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

"${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build

driver_id="$("${COMPOSE[@]}" ps -q driver)"
if [[ -z "$driver_id" ]]; then
  echo "Production lab driver container was not created" >&2
  exit 1
fi

while [[ "$(docker inspect -f '{{.State.Running}}' "$driver_id")" == "true" ]]; do
  sleep 1
done

driver_exit="$(docker inspect -f '{{.State.ExitCode}}' "$driver_id")"
"${COMPOSE[@]}" logs --no-color driver | tee "$ARTIFACT_DIR/driver.log"
if [[ "$driver_exit" != "0" ]]; then
  echo "Production lab driver failed with exit code $driver_exit" >&2
  exit "$driver_exit"
fi

"${COMPOSE[@]}" exec -T executor sh -lc '
  test -z "${RUNDIFF_GITHUB_PRIVATE_KEY_PATH:-}" &&
  test -z "${RUNDIFF_GITHUB_WEBHOOK_SECRET:-}" &&
  test -z "${RUNDIFF_GITHUB_APP_ID:-}" &&
  test -z "${RUNDIFF_REMOTE_EXECUTOR_URL:-}" &&
  test -z "${RUNDIFF_REMOTE_EXECUTOR_TOKEN:-}" &&
  test -z "${RUNDIFF_EXECUTOR:-}"
'

"${COMPOSE[@]}" exec -T executor bin/rails runner '
  records = RunDiffExecutorRequest.all.to_a
  raise "Expected at least two executor ledger records" if records.size < 2
  raise "Expected completed executor records" unless records.all? { |record| record.status == "completed" }

  serialized = records.map(&:attributes).to_json
  forbidden = ["repository_capability", "x-access-token", "github-app.pem", "rundiff-production-lab-webhook-secret"]
  leaked = forbidden.select { |value| serialized.include?(value) }
  raise "Repository capability or GitHub secret persisted in executor ledger: #{leaked.join(", ")}" unless leaked.empty?

  puts "production_lab_executor_records=#{records.size}"
  puts "production_lab_executor_github_secrets=false"
  puts "production_lab_repository_capability_persisted=false"
' | tee "$ARTIFACT_DIR/executor-proof.log"

cat > "$ARTIFACT_DIR/result.env" <<'EOF'
production_lab_gate=passed
EOF

echo "production_lab_gate=passed"
