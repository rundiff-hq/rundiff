#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    printf 'remote-topology: required environment variable is missing: %s\n' "$name" >&2
    exit 64
  }
}

for name in   RUNDIFF_PROOF_REPOSITORY_TOKEN   RUNDIFF_PROOF_REPOSITORY   RUNDIFF_PROOF_PULL_REQUEST_NUMBER   RUNDIFF_PROOF_BASELINE_REF   RUNDIFF_PROOF_CANDIDATE_REF   RUNDIFF_PROOF_BASELINE_SHA   RUNDIFF_PROOF_CANDIDATE_SHA
do
  require_env "$name"
done

mkdir -p "$ARTIFACT_DIR"

run_id="${GITHUB_RUN_ID:-$$}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
suffix="$run_id-$run_attempt"

RUNDIFF_IMAGE="${RUNDIFF_IMAGE:-rundiff-remote-topology:${GITHUB_SHA:-local}}"
RUNDIFF_EXECUTOR_SERVICE_TOKEN="${RUNDIFF_EXECUTOR_SERVICE_TOKEN:-lab-executor-service-token}"
RUNDIFF_PROOF_EXECUTION_ID="${RUNDIFF_PROOF_EXECUTION_ID:-remote-topology-$suffix}"

NETWORK="rundiff-remote-topology-$suffix"
POSTGRES_CONTAINER="rundiff-remote-topology-postgres-$suffix"
EXECUTOR_CONTAINER="rundiff-remote-topology-executor-$suffix"

POSTGRES_USER="postgres"
POSTGRES_PASSWORD="postgres"
POSTGRES_DB="rundiff_executor_lab"
EXECUTOR_DATABASE_URL="postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_CONTAINER:5432/$POSTGRES_DB"
EXECUTOR_URL="http://$EXECUTOR_CONTAINER:4010/v1/executions"

capture_state() {
  docker ps -a > "$ARTIFACT_DIR/docker-ps.txt" 2>&1 || true
  docker network inspect "$NETWORK" > "$ARTIFACT_DIR/network.json" 2>&1 || true
  docker logs "$POSTGRES_CONTAINER" > "$ARTIFACT_DIR/postgres.log" 2>&1 || true
  docker logs "$EXECUTOR_CONTAINER" > "$ARTIFACT_DIR/executor.log" 2>&1 || true
}

cleanup() {
  local exit_code=$?

  capture_state

  docker rm -f "$EXECUTOR_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$POSTGRES_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

docker network create "$NETWORK" >/dev/null

docker run -d   --name "$POSTGRES_CONTAINER"   --network "$NETWORK"   -e POSTGRES_USER="$POSTGRES_USER"   -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD"   -e POSTGRES_DB="$POSTGRES_DB"   postgres:17 >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    break
  fi

  if [[ "$attempt" -eq 60 ]]; then
    echo "PostgreSQL did not become ready" >&2
    docker logs "$POSTGRES_CONTAINER" >&2 || true
    exit 1
  fi

  sleep 1
done

echo "remote_topology_postgres=ready"

docker build -t "$RUNDIFF_IMAGE" "$ROOT"

docker run --rm   --network "$NETWORK"   -e SECRET_KEY_BASE_DUMMY=1   -e RAILS_ENV=production   -e DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e SOLID_QUEUE_DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e RUNDIFF_RUNTIME_ROLE=executor_service   -e RUNDIFF_EXECUTOR_SERVICE_TOKEN="$RUNDIFF_EXECUTOR_SERVICE_TOKEN"   -e RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone   "$RUNDIFF_IMAGE" bin/rails db:prepare

docker run -d   --name "$EXECUTOR_CONTAINER"   --network "$NETWORK"   -e SECRET_KEY_BASE_DUMMY=1   -e RAILS_ENV=production   -e DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e SOLID_QUEUE_DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e RUNDIFF_RUNTIME_ROLE=executor_service   -e RUNDIFF_EXECUTOR_SERVICE_TOKEN="$RUNDIFF_EXECUTOR_SERVICE_TOKEN"   -e RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone   -e RUNDIFF_LOCAL_POSTGRES_URL="postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_CONTAINER:5432"   "$RUNDIFF_IMAGE" bin/rails server -b 0.0.0.0 -p 4010 >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$EXECUTOR_CONTAINER" ruby -rnet/http -ruri -e '
    response = Net::HTTP.get_response(URI("http://127.0.0.1:4010/ready"))
    abort "not ready: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    print response.body
  ' > "$ARTIFACT_DIR/ready.json" 2>/dev/null; then
    break
  fi

  if [[ "$attempt" -eq 60 ]]; then
    echo "Executor did not become ready" >&2
    docker logs "$EXECUTOR_CONTAINER" >&2 || true
    exit 1
  fi

  sleep 1
done

cat "$ARTIFACT_DIR/ready.json"
echo
echo "remote_topology_executor=ready"

docker exec "$EXECUTOR_CONTAINER" sh -lc '
  test -z "${RUNDIFF_GITHUB_PRIVATE_KEY_PATH:-}" &&
  test -z "${RUNDIFF_GITHUB_WEBHOOK_SECRET:-}" &&
  test -z "${RUNDIFF_GITHUB_APP_ID:-}" &&
  test -z "${RUNDIFF_REMOTE_EXECUTOR_URL:-}" &&
  test -z "${RUNDIFF_REMOTE_EXECUTOR_TOKEN:-}"
'

echo "remote_topology_executor_github_secrets=false"

docker run --rm   --network "$NETWORK"   -e SECRET_KEY_BASE_DUMMY=1   -e RAILS_ENV=production   -e DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e RUNDIFF_REMOTE_EXECUTOR_URL="$EXECUTOR_URL"   -e RUNDIFF_REMOTE_EXECUTOR_TOKEN="$RUNDIFF_EXECUTOR_SERVICE_TOKEN"   -e RUNDIFF_PROOF_REPOSITORY_TOKEN   -e RUNDIFF_PROOF_EXECUTION_ID="$RUNDIFF_PROOF_EXECUTION_ID"   -e RUNDIFF_PROOF_REPOSITORY   -e RUNDIFF_PROOF_PULL_REQUEST_NUMBER   -e RUNDIFF_PROOF_BASELINE_REF   -e RUNDIFF_PROOF_CANDIDATE_REF   -e RUNDIFF_PROOF_BASELINE_SHA   -e RUNDIFF_PROOF_CANDIDATE_SHA   "$RUNDIFF_IMAGE" ruby script/prove_remote_executor_topology.rb |
  tee "$ARTIFACT_DIR/topology-proof.log"

docker run --rm   --network "$NETWORK"   -e SECRET_KEY_BASE_DUMMY=1   -e RAILS_ENV=production   -e DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e SOLID_QUEUE_DATABASE_URL="$EXECUTOR_DATABASE_URL"   -e RUNDIFF_RUNTIME_ROLE=executor_service   -e RUNDIFF_EXECUTOR_SERVICE_TOKEN="$RUNDIFF_EXECUTOR_SERVICE_TOKEN"   -e RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone   -e RUNDIFF_PROOF_EXECUTION_ID="$RUNDIFF_PROOF_EXECUTION_ID"   -e EXPECTED_REPOSITORY_TOKEN="$RUNDIFF_PROOF_REPOSITORY_TOKEN"   "$RUNDIFF_IMAGE" bin/rails runner '
    record = RunDiffExecutorRequest.find_by!(idempotency_key: "#{ENV.fetch("RUNDIFF_PROOF_EXECUTION_ID")}:1")
    raise "Executor request did not complete" unless record.status == "completed"

    serialized = record.attributes.to_json
    if serialized.include?(ENV.fetch("EXPECTED_REPOSITORY_TOKEN"))
      raise "Repository capability leaked into executor ledger"
    end

    puts "executor_ledger_status=completed"
    puts "repository_capability_persisted=false"
  ' | tee "$ARTIFACT_DIR/ledger-proof.log"

cat > "$ARTIFACT_DIR/result.env" <<EOF
remote_executor_topology_proof=passed
execution_id=$RUNDIFF_PROOF_EXECUTION_ID
executor_github_secrets=false
repository_capability_persisted=false
EOF

echo "remote_executor_topology_proof=passed"
