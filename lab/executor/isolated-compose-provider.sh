#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

run_key="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-$$}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"

RUNDIFF_EXECUTOR_IMAGE="${RUNDIFF_EXECUTOR_IMAGE:-rundiff-isolated-executor:$run_key}"
RUNDIFF_PROVIDER_IMAGE="${RUNDIFF_PROVIDER_IMAGE:-rundiff-compose-provider:$run_key}"
RUNDIFF_PROVIDER_VOLUME="${RUNDIFF_PROVIDER_VOLUME:-rundiff-provider-$run_id-$run_attempt}"
RUNDIFF_COMPOSE_PROVIDER_SOCKET="${RUNDIFF_COMPOSE_PROVIDER_SOCKET:-/run/rundiff-provider/provider.sock}"
PROVIDER_CONTAINER="${RUNDIFF_PROVIDER_CONTAINER:-rundiff-compose-provider-$run_id-$run_attempt}"
GO_PROOF_DIR="$(mktemp -d)"
GO_SERVICE_TEST="$GO_PROOF_DIR/services.test"

mkdir -p "$ARTIFACT_DIR"

cleanup() {
  local exit_code=$?

  docker logs "$PROVIDER_CONTAINER" > "$ARTIFACT_DIR/provider.log" 2>&1 || true
  docker ps -a > "$ARTIFACT_DIR/docker-ps.txt" 2>&1 || true
  docker network ls > "$ARTIFACT_DIR/docker-networks.txt" 2>&1 || true
  docker volume ls > "$ARTIFACT_DIR/docker-volumes.txt" 2>&1 || true

  docker rm -f "$PROVIDER_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm -f "$RUNDIFF_PROVIDER_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$GO_PROOF_DIR"

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

echo "executor_image=$RUNDIFF_EXECUTOR_IMAGE"
echo "provider_image=$RUNDIFF_PROVIDER_IMAGE"
echo "provider_volume=$RUNDIFF_PROVIDER_VOLUME"

docker build -t "$RUNDIFF_EXECUTOR_IMAGE" "$ROOT"
docker build -f "$ROOT/Dockerfile.compose-provider" -t "$RUNDIFF_PROVIDER_IMAGE" "$ROOT"

(
  cd "$ROOT/apps/executor-go"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go test -c -o "$GO_SERVICE_TEST" ./internal/services
)

docker volume create "$RUNDIFF_PROVIDER_VOLUME" >/dev/null

docker run -d --name "$PROVIDER_CONTAINER"   -v /var/run/docker.sock:/var/run/docker.sock   -v "$RUNDIFF_PROVIDER_VOLUME:/run/rundiff-provider"   -e RUNDIFF_COMPOSE_PROVIDER_SOCKET="$RUNDIFF_COMPOSE_PROVIDER_SOCKET"   "$RUNDIFF_PROVIDER_IMAGE" >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$PROVIDER_CONTAINER" test -S "$RUNDIFF_COMPOSE_PROVIDER_SOCKET"; then
    break
  fi

  if [[ "$attempt" -eq 60 ]]; then
    docker logs "$PROVIDER_CONTAINER" >&2 || true
    echo "Provider control socket did not become ready" >&2
    exit 1
  fi

  sleep 1
done

docker run --rm   -v "$RUNDIFF_PROVIDER_VOLUME:/run/rundiff-provider"   "$RUNDIFF_EXECUTOR_IMAGE"   sh -c 'test ! -S /var/run/docker.sock && ! command -v docker'

docker run --rm --user 10001:10001   -v "$RUNDIFF_PROVIDER_VOLUME:/run/rundiff-provider"   -e RUNDIFF_COMPOSE_PROVIDER_SOCKET="$RUNDIFF_COMPOSE_PROVIDER_SOCKET"   "$RUNDIFF_EXECUTOR_IMAGE"   ruby -rsocket -e '
    begin
      UNIXSocket.new(ENV.fetch("RUNDIFF_COMPOSE_PROVIDER_SOCKET"))
      abort "subject UID unexpectedly opened provider control socket"
    rescue Errno::EACCES
      puts "subject_provider_authority_access=false"
    end
  ' | tee "$ARTIFACT_DIR/privilege-boundary.log"

docker run --rm --network host   -v "$RUNDIFF_PROVIDER_VOLUME:/run/rundiff-provider"   -e RUNDIFF_COMPOSE_PROVIDER_SOCKET="$RUNDIFF_COMPOSE_PROVIDER_SOCKET"   "$RUNDIFF_EXECUTOR_IMAGE"   ruby script/prove_isolated_compose_provider.rb |
  tee "$ARTIFACT_DIR/provider-proof.log"

docker run --rm --network host \
  -v "$RUNDIFF_PROVIDER_VOLUME:/run/rundiff-provider" \
  -v "$GO_SERVICE_TEST:/tmp/rundiff-go-services-test:ro" \
  -e RUNDIFF_COMPOSE_PROVIDER_SOCKET="$RUNDIFF_COMPOSE_PROVIDER_SOCKET" \
  -e RUNDIFF_GO_COMPOSE_E2E=1 \
  "$RUNDIFF_EXECUTOR_IMAGE" \
  /tmp/rundiff-go-services-test -test.run '^TestIsolatedComposeProviderEndToEnd

if docker ps -a --filter label=com.docker.compose.project --format '{{.Names}}' | grep '^rundiff-' ; then
  echo "Compose containers leaked after proof" >&2
  docker ps -a >&2
  exit 1
fi

if docker network ls --filter label=com.docker.compose.project --format '{{.Name}}' | grep '^rundiff-' ; then
  echo "Compose networks leaked after proof" >&2
  docker network ls >&2
  exit 1
fi

echo "isolated_compose_provider_proof=passed"
 -test.v |
  tee "$ARTIFACT_DIR/go-provider-proof.log"

if docker ps -a --filter label=com.docker.compose.project --format '{{.Names}}' | grep '^rundiff-' ; then
  echo "Compose containers leaked after proof" >&2
  docker ps -a >&2
  exit 1
fi

if docker network ls --filter label=com.docker.compose.project --format '{{.Name}}' | grep '^rundiff-' ; then
  echo "Compose networks leaked after proof" >&2
  docker network ls >&2
  exit 1
fi

echo "isolated_compose_provider_proof=passed"
