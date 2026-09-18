#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

mkdir -p "$ARTIFACT_DIR"

output="$ARTIFACT_DIR/test.log"

(
  cd "$ROOT"
  bundle exec rails test test/lib/rundiff/executor/http_adapter_test.rb -n '/timeout/'
) | tee "$output"

grep -Eq '[1-9][0-9]* runs?, [1-9][0-9]* assertions?' "$output"
grep -Fq '0 failures' "$output"
grep -Fq '0 errors' "$output"

cat > "$ARTIFACT_DIR/result.env" <<'EOF'
executor_timeout_diagnostics_proof=passed
read_timeout_phase=remote_executor_wait
open_timeout_phase=remote_executor_connect
execution_id_required=true
secret_leak_expected=false
EOF

echo "executor_timeout_diagnostics_proof=passed"
