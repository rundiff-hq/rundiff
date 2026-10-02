#!/usr/bin/env bash
set -euo pipefail

sha="$1"
label="$2"
run_id="$3"
scenario_id="$4"
expected_started_at="$5"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

cd /tmp/rundiff-subject
git checkout --detach "$sha" >&2

docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >&2
actual_started_at="$(docker_cmd inspect -f '{{.State.StartedAt}}' rundiff-postgres)"
if [[ "$actual_started_at" != "$expected_started_at" ]]; then
  echo "inherited PostgreSQL StartedAt mismatch: expected=$expected_started_at actual=$actual_started_at" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${subject_pid:-}" ]]; then
    kill "$subject_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

PORT=3000 \
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/rundiff_bridge \
  nohup node server.mjs >/tmp/rundiff-subject.log 2>&1 &
subject_pid=$!

ready=0
for _ in $(seq 1 80); do
  if curl -fsS http://127.0.0.1:3000/health >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$subject_pid" >/dev/null 2>&1; then
    cat /tmp/rundiff-subject.log >&2
    exit 1
  fi
  sleep 0.25
done
if [[ "$ready" != "1" ]]; then
  cat /tmp/rundiff-subject.log >&2
  exit 1
fi

python3 /tmp/rundiff_resource_snapshot.py role_active "$label" 0 \
  >/tmp/rundiff-resource.json

RUNDIFF_SCENARIO_BASE_URL=http://127.0.0.1:3000 \
RUNDIFF_SCENARIO_PATH=/widgets \
RUNDIFF_RUN_ID="$run_id" \
RUNDIFF_SCENARIO_ID="$scenario_id" \
RUNDIFF_SUBJECT=github-pull-request \
RUNDIFF_EXECUTION_LABEL="$label" \
RUNDIFF_EXECUTION_SHA="$sha" \
RUNDIFF_OUTPUT=/tmp/rundiff-capture.json \
RUNDIFF_SENSOR_SCHEMA_VERSION=1 \
RUNDIFF_SENSOR_ADAPTER=node \
RUNDIFF_CAPTURE_RUNTIME=tool_owned_node_http \
RUNDIFF_SENSOR_RUNTIME=node \
  node /tmp/rundiff_capture_node.mjs >/dev/null

python3 - /tmp/rundiff-capture.json /tmp/rundiff-resource.json <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    capture = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    resource = json.load(handle)

print(json.dumps(
    {"Capture": capture, "Resource": resource},
    separators=(",", ":"),
))
PY
