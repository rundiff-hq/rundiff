#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

mkdir -p "$ARTIFACT_DIR"

output="$ARTIFACT_DIR/proof.log"

(
  cd "$ROOT"
  bundle exec ruby script/prove_remote_executor_timeout_diagnostics.rb
) | tee "$output"

grep -Fq 'executor_timeout_diagnostics_proof=passed' "$output"
grep -Fq 'timeout_phase=remote_executor_wait error_class=Net::ReadTimeout verified=true' "$output"
grep -Fq 'timeout_phase=remote_executor_connect error_class=Net::OpenTimeout verified=true' "$output"
grep -Fq 'secret_leak=false' "$output"

cat > "$ARTIFACT_DIR/result.env" <<'EOF'
executor_timeout_diagnostics_proof=passed
read_timeout_phase=remote_executor_wait
open_timeout_phase=remote_executor_connect
execution_id_required=true
secret_leak=false
database_required=false
EOF

echo "executor_timeout_lab=passed"
