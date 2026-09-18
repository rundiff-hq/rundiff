#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

mkdir -p "$ARTIFACT_DIR"

command -v ruby >/dev/null 2>&1 || {
  echo "Ruby is required for executor/compose-service" >&2
  exit 1
}

docker compose version | tee "$ARTIFACT_DIR/docker-compose-version.txt"
test -S /var/run/docker.sock

ruby "$ROOT/script/prove_compose_service_provider.rb" |
  tee "$ARTIFACT_DIR/proof.log"

echo "compose_service_proof=passed"
