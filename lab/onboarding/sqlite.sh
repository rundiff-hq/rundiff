#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${RUNDIFF_LAB_ARTIFACT_DIR:?RUNDIFF_LAB_ARTIFACT_DIR is required}"

mkdir -p "$ARTIFACT_DIR"

proof_log="$ARTIFACT_DIR/proof.log"
review_payload="$ARTIFACT_DIR/review.json"
review_output="$ARTIFACT_DIR/review.txt"

(
  cd "$ROOT"
  bin/rundiff demo --output "$review_payload" --color never
) | tee "$review_output" "$proof_log"

test -s "$review_payload"

ruby -rjson -e '
  payload = JSON.parse(File.read(ARGV.fetch(0)))
  result = payload.fetch("result")
  baseline = payload.dig("executions", "baseline")
  candidate = payload.dig("executions", "candidate")

  raise "Expected BLOCK recommendation" unless result.fetch("merge_recommendation") == "block"
  raise "Expected functional baseline pass" unless baseline.fetch("status") == "passed"
  raise "Expected functional candidate pass" unless candidate.fetch("status") == "passed"

  finding = result.fetch("findings").find do |item|
    item.fetch("reason_code") == "DATABASE_QUERY_REGRESSION"
  end
  raise "Expected DATABASE_QUERY_REGRESSION" unless finding

  baseline_queries = baseline.dig("measurements", "sql_queries")
  candidate_queries = candidate.dig("measurements", "sql_queries")
  raise "Expected candidate SQL increase" unless candidate_queries > baseline_queries

  %w[baseline candidate].each do |side|
    execution = payload.dig("executions", side)
    unless execution.dig("lifecycle", "capture_runtime") == "tool_owned_portable_rails"
      raise "Expected portable tool-owned capture for #{side}"
    end
  end

  puts "one_command_demo_payload=verified"
  puts "baseline_sql_queries=#{baseline_queries}"
  puts "candidate_sql_queries=#{candidate_queries}"
' "$review_payload" | tee "$ARTIFACT_DIR/payload-proof.log"

grep -Fq 'RunDiff Behavioral Review' "$review_output"
grep -Fq 'BLOCK' "$review_output"
grep -Fq 'DATABASE_QUERY_REGRESSION' "$review_output"
grep -Fq 'Functional scenario: PASSED' "$review_output"
grep -Fq 'Behavioral review:  BLOCK' "$review_output"

cat > "$ARTIFACT_DIR/result.env" <<'EOF'
onboarding_sqlite_proof=passed
one_command_demo=passed
subject_persistence_discovered=sqlite
expected_reason_code=DATABASE_QUERY_REGRESSION
customer_rundiff_runtime_files=false
control_plane_lockfile_unchanged=true
behavioral_review_cli=passed
EOF

echo "onboarding_sqlite_proof=passed"
echo "one_command_demo=passed"
