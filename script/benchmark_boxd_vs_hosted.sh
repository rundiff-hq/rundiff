#!/usr/bin/env bash
set -euo pipefail

pairs="${RUNDIFF_PROVIDER_BENCHMARK_PAIRS:-5}"
output_root="${RUNDIFF_PROVIDER_BENCHMARK_OUTPUT_ROOT:-tmp/rundiff/provider-benchmark}"
executor_bin="${RUNDIFF_PROVIDER_BENCHMARK_EXECUTOR_BIN:-/tmp/rundiff-executor}"
boxd_test_bin="${RUNDIFF_PROVIDER_BENCHMARK_BOXD_TEST_BIN:-/tmp/rundiff-boxd-live.test}"
tool_sha="${RUNDIFF_BOXD_TOOL_SHA:?RUNDIFF_BOXD_TOOL_SHA is required}"

baseline_sha="e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb"
candidate_sha="a1663f54380e3a117989ebc6f1ab8f525f6bed4e"
repository="rundiff-hq/example-node-express-postgres"

if ! [[ "$pairs" =~ ^[1-9][0-9]*$ ]] || (( pairs < 1 || pairs > 10 )); then
  echo "RUNDIFF_PROVIDER_BENCHMARK_PAIRS must be between 1 and 10" >&2
  exit 2
fi

mkdir -p "$output_root/raw"
samples_jsonl="$output_root/samples.jsonl"
: > "$samples_jsonl"

now_ms() {
  date +%s%3N
}

assert_block_result() {
  local result_path="$1"
  jq -e '.status == "succeeded" and .payload.result.decision == "regression" and .payload.result.merge_recommendation == "block" and any(.payload.result.findings[]?; .reason_code == "NEW_RUNTIME_ERROR" and .finding_severity == "BLOCKING")' "$result_path" >/dev/null
}

run_hosted() {
  local pair="$1"
  local position="$2"
  local id
  id="$(printf "%02d" "$pair")"
  local root="$output_root/raw/hosted-$id"
  mkdir -p "$root"

  local request="$root/request.json"
  local result="$root/result.json"
  local journal="$root/journal.jsonl"
  local metrics="$root/metrics.jsonl"
  local stdout="$root/stdout.log"
  local stderr="$root/stderr.log"

  cat >"$request" <<JSON
{
  "schema_version": "1",
  "execution_id": "provider-benchmark-hosted-$id",
  "scenario_id": "node.http.widgets",
  "baseline_sha": "$baseline_sha",
  "candidate_sha": "$candidate_sha",
  "attempt_number": 1,
  "context": {
    "repository": "$repository",
    "pull_request_number": 1,
    "baseline_ref": "main",
    "candidate_ref": "pull/1/head",
    "candidate_repository": "$repository"
  }
}
JSON

  local started ended
  started="$(now_ms)"
  "$executor_bin" run-local --request "$request" --result "$result" --journal "$journal" --metrics "$metrics" --cwd "$GITHUB_WORKSPACE" >"$stdout" 2>"$stderr"
  ended="$(now_ms)"

  assert_block_result "$result"

  jq -nc --arg provider hosted --argjson pair "$pair" --argjson sequence_position "$position" --argjson wall_ms "$((ended - started))" --arg result_path "$result" --arg metrics_path "$metrics" '{provider:$provider,pair:$pair,sequence_position:$sequence_position,wall_ms:$wall_ms,outcome:"block",finding:"NEW_RUNTIME_ERROR",result_path:$result_path,metrics_path:$metrics_path}' >>"$samples_jsonl"
}

extract_metric() {
  local key="$1"
  local log="$2"
  local value
  value="$(grep -Eo "${key}=[0-9]+" "$log" | tail -1 | cut -d= -f2 || true)"
  if [[ -z "$value" ]]; then
    echo "missing Boxd metric $key in $log" >&2
    return 1
  fi
  printf '%s' "$value"
}

run_boxd() {
  local pair="$1"
  local position="$2"
  local id
  id="$(printf "%02d" "$pair")"
  local root="$output_root/raw/boxd-$id"
  mkdir -p "$root"
  local log="$root/test.log"

  local proof_id started ended
  proof_id="bench-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$id"
  started="$(now_ms)"

  (
    cd "$GITHUB_WORKSPACE/apps/executor-go/internal/compute/boxd"
    RUNDIFF_BOXD_PROOF_ID="$proof_id" RUNDIFF_BOXD_TOOL_SHA="$tool_sha" "$boxd_test_bin" -test.v -test.run '^TestLiveBehavioralDiff$' -test.count=1
  ) >"$log" 2>&1

  ended="$(now_ms)"

  grep -q 'product.behavioral_diff=block' "$log"
  grep -q 'product.finding=NEW_RUNTIME_ERROR' "$log"

  local create_ms prepare_ms fork_ms base_ms candidate_ms execution_ms cleanup_pair_ms cleanup_golden_ms
  create_ms="$(extract_metric provider.create.golden_ready_ms "$log")"
  prepare_ms="$(extract_metric subject.golden_prepare_ms "$log")"
  fork_ms="$(extract_metric provider.fork_pair_ready_ms "$log")"
  base_ms="$(extract_metric scenario.baseline_capture_ms "$log")"
  candidate_ms="$(extract_metric scenario.candidate_capture_ms "$log")"
  execution_ms="$(extract_metric execution.total_ms "$log")"
  cleanup_pair_ms="$(extract_metric provider.cleanup.pair_ms "$log")"
  cleanup_golden_ms="$(extract_metric provider.cleanup.golden_ms "$log")"

  jq -nc --arg provider boxd --argjson pair "$pair" --argjson sequence_position "$position" --argjson wall_ms "$((ended - started))" --argjson create_ms "$create_ms" --argjson golden_prepare_ms "$prepare_ms" --argjson fork_pair_ms "$fork_ms" --argjson baseline_capture_ms "$base_ms" --argjson candidate_capture_ms "$candidate_ms" --argjson execution_ms "$execution_ms" --argjson cleanup_pair_ms "$cleanup_pair_ms" --argjson cleanup_golden_ms "$cleanup_golden_ms" --arg log_path "$log" '{provider:$provider,pair:$pair,sequence_position:$sequence_position,wall_ms:$wall_ms,outcome:"block",finding:"NEW_RUNTIME_ERROR",phases:{create_golden_ms:$create_ms,golden_prepare_ms:$golden_prepare_ms,fork_pair_ms:$fork_pair_ms,baseline_capture_ms:$baseline_capture_ms,candidate_capture_ms:$candidate_capture_ms,execution_before_deferred_cleanup_ms:$execution_ms,cleanup_pair_ms:$cleanup_pair_ms,cleanup_golden_ms:$cleanup_golden_ms},log_path:$log_path}' >>"$samples_jsonl"
}

for ((pair = 1; pair <= pairs; pair++)); do
  if (( pair % 2 == 1 )); then
    run_hosted "$pair" 1
    run_boxd "$pair" 2
  else
    run_boxd "$pair" 1
    run_hosted "$pair" 2
  fi
done

python3 script/provider_benchmark_report.py --samples "$samples_jsonl" --output "$output_root/report.json"
cat "$output_root/report.json"
