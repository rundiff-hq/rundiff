#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

mkdir -p "$ARTIFACT_DIR"

output="$ARTIFACT_DIR/proof.log"

(
  cd "$ROOT"
  bundle exec ruby script/prove_rails_sqlite_subject.rb
) | tee "$output"

grep -Eq '^result_status=(succeeded|completed)
grep -Fq 'reason_code=DATABASE_QUERY_REGRESSION' "$output"
grep -Fq 'subject_persistence_discovered=sqlite' "$output"
grep -Fq 'candidate_config_applied_to_baseline=true' "$output"
grep -Fq 'customer_rundiff_runtime_files=false' "$output"
grep -Fq 'control_plane_lockfile_unchanged=true' "$output"

cat > "$ARTIFACT_DIR/result.env" <<'EOF'
onboarding_sqlite_proof=passed
subject_persistence=sqlite
expected_reason_code=DATABASE_QUERY_REGRESSION
customer_rundiff_runtime_files=false
control_plane_lockfile_unchanged=true
EOF

echo "onboarding_sqlite_proof=passed"
 "$output"
grep -Fq 'reason_code=DATABASE_QUERY_REGRESSION' "$output"
grep -Fq 'subject_persistence_discovered=sqlite' "$output"
grep -Fq 'candidate_config_applied_to_baseline=true' "$output"
grep -Fq 'customer_rundiff_runtime_files=false' "$output"
grep -Fq 'control_plane_lockfile_unchanged=true' "$output"

cat > "$ARTIFACT_DIR/result.env" <<'EOF'
onboarding_sqlite_proof=passed
subject_persistence=sqlite
expected_reason_code=DATABASE_QUERY_REGRESSION
customer_rundiff_runtime_files=false
control_plane_lockfile_unchanged=true
EOF

echo "onboarding_sqlite_proof=passed"
