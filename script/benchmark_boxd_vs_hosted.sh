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
agent_log="$output_root/raw/boxd-agent.log"
agent_ready="$output_root/raw/boxd-agent-ready.json"
agent_closed="$output_root/raw/boxd-agent-closed.json"
agent_metadata="$output_root/raw/boxd-agent-metadata.json"
: > "$samples_jsonl"
: > "$agent_log"

now_ms() {
  date +%s%3N
}

assert_block_result() {
  local result_path="$1"
  jq -e '.status == "succeeded" and .payload.result.decision == "regression" and .payload.result.merge_recommendation == "block" and any(.payload.result.findings[]?; .reason_code == "NEW_RUNTIME_ERROR" and .finding_severity == "BLOCKING")' "$result_path" >/dev/null
}

agent_started=0
agent_closed_cleanly=0
agent_read_fd=""
agent_write_fd=""
agent_pid=""
AGENT_RESPONSE=""

read_agent_response() {
  AGENT_RESPONSE=""
  local line
  while IFS= read -r line <&"$agent_read_fd"; do
    printf '%s\n' "$line" >>"$agent_log"
    if [[ "$line" == RUNDIFF_AGENT\ * ]]; then
      AGENT_RESPONSE="${line#RUNDIFF_AGENT }"
      return 0
    fi
  done
  echo "Boxd benchmark agent exited before returning a structured response" >&2
  return 1
}

cleanup_agent() {
  if (( agent_started == 0 )); then
    return
  fi

  if (( agent_closed_cleanly == 0 )); then
    printf '%s\n' '{"op":"close"}' >&"$agent_write_fd" 2>/dev/null || true
    read_agent_response >/dev/null 2>&1 || true
  fi

  exec {agent_write_fd}>&- 2>/dev/null || true
  exec {agent_read_fd}<&- 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
}

start_boxd_agent() {
  local proof_id
  proof_id="provider-bench-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

  coproc BOXD_AGENT {
    cd "$GITHUB_WORKSPACE/apps/executor-go/internal/compute/boxd"
    RUNDIFF_BOXD_PROOF_ID="$proof_id" \
      RUNDIFF_BOXD_TOOL_SHA="$tool_sha" \
      "$boxd_test_bin" \
      -test.v \
      -test.run '^TestLiveOptimizedProviderBenchmarkAgent$' \
      -test.count=1 2>&1
  }

  agent_pid="$BOXD_AGENT_PID"
  exec {agent_read_fd}<&"${BOXD_AGENT[0]}"
  exec {agent_write_fd}>&"${BOXD_AGENT[1]}"
  agent_started=1
  trap cleanup_agent EXIT

  read_agent_response
  printf '%s\n' "$AGENT_RESPONSE" >"$agent_ready"
  jq -e '.type == "ready" and .create_golden_ms >= 0 and .prepare_golden_ms >= 0 and (.parent_started_at | length > 0)' "$agent_ready" >/dev/null
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

  jq -nc \
    --arg provider hosted \
    --argjson pair "$pair" \
    --argjson sequence_position "$position" \
    --argjson wall_ms "$((ended - started))" \
    --arg result_path "$result" \
    --arg metrics_path "$metrics" \
    '{provider:$provider,pair:$pair,sequence_position:$sequence_position,wall_ms:$wall_ms,outcome:"block",finding:"NEW_RUNTIME_ERROR",result_path:$result_path,metrics_path:$metrics_path}' \
    >>"$samples_jsonl"
}

run_boxd() {
  local pair="$1"
  local position="$2"
  local id
  id="$(printf "%02d" "$pair")"
  local root="$output_root/raw/boxd-$id"
  mkdir -p "$root"

  local response="$root/agent-response.json"
  local started ended
  started="$(now_ms)"
  printf '{"op":"run","pair":%d,"sequence_position":%d}\n' "$pair" "$position" >&"$agent_write_fd"
  read_agent_response
  ended="$(now_ms)"
  printf '%s\n' "$AGENT_RESPONSE" >"$response"

  jq -e '.type == "sample" and .sample.mode == "inherited_running" and .sample.decision == "block" and .sample.finding == "NEW_RUNTIME_ERROR"' "$response" >/dev/null

  jq -nc \
    --arg provider boxd \
    --argjson pair "$pair" \
    --argjson sequence_position "$position" \
    --argjson wall_ms "$((ended - started))" \
    --slurpfile response "$response" \
    '($response[0].sample) as $sample | {
      provider:$provider,
      pair:$pair,
      sequence_position:$sequence_position,
      wall_ms:$wall_ms,
      outcome:"block",
      finding:"NEW_RUNTIME_ERROR",
      agent_total_ms:$sample.total_ms,
      phases:{
        fork_pair_ms:$sample.pair_fork_ready_ms,
        inherited_postgres_ready_ms:$sample.inherited_postgres_ready_ms,
        baseline_capture_ms:$sample.baseline_capture_ms,
        candidate_capture_ms:$sample.candidate_capture_ms,
        role_critical_path_ms:$sample.role_critical_path_ms,
        comparison_ms:$sample.comparison_ms,
        cleanup_pair_ms:$sample.cleanup_ms
      }
    }' >>"$samples_jsonl"
}

finish_boxd_agent() {
  printf '%s\n' '{"op":"close"}' >&"$agent_write_fd"
  read_agent_response
  printf '%s\n' "$AGENT_RESPONSE" >"$agent_closed"
  jq -e '.type == "closed" and .golden_cleanup_ms >= 0' "$agent_closed" >/dev/null
  agent_closed_cleanly=1

  exec {agent_write_fd}>&-
  exec {agent_read_fd}<&-
  wait "$agent_pid"
  agent_started=0
  trap - EXIT

  jq -n \
    --slurpfile ready "$agent_ready" \
    --slurpfile closed "$agent_closed" \
    '{
      create_golden_ms:$ready[0].create_golden_ms,
      prepare_golden_ms:$ready[0].prepare_golden_ms,
      golden_cleanup_ms:$closed[0].golden_cleanup_ms,
      parent_started_at:$ready[0].parent_started_at
    }' >"$agent_metadata"
}

start_boxd_agent

for ((pair = 1; pair <= pairs; pair++)); do
  if (( pair % 2 == 1 )); then
    run_hosted "$pair" 1
    run_boxd "$pair" 2
  else
    run_boxd "$pair" 1
    run_hosted "$pair" 2
  fi
done

finish_boxd_agent

python3 script/provider_benchmark_report.py \
  --samples "$samples_jsonl" \
  --boxd-metadata "$agent_metadata" \
  --output "$output_root/report.json"
cat "$output_root/report.json"
