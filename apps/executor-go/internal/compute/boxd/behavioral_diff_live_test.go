package boxd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/comparison"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/sensor"
)

const (
	boxdFixtureRepository   = "https://github.com/rundiff-hq/example-node-express-postgres.git"
	boxdFixtureBaselineSHA  = "e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb"
	boxdFixtureCandidateSHA = "a1663f54380e3a117989ebc6f1ab8f525f6bed4e"
)

func TestLiveBehavioralDiff(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd behavioral diff proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd behavioral diff proof")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live Boxd behavioral diff proof")
	}
	toolSHA := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_TOOL_SHA"))
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for the live Boxd behavioral diff proof")
	}

	client, err := NewSessionPairSDK(
		"node",
		"sdkbridge/session.mjs",
		"sdkbridge/bridge.mjs",
	)
	if err != nil {
		t.Fatalf("start SDK pair sessions: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close SDK pair sessions: %v", closeErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	totalStarted := time.Now()
	parentName := "rundiff-dp-" + proofID
	baselineName := "rundiff-db-" + proofID
	candidateName := "rundiff-dc-" + proofID

	createStarted := time.Now()
	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create golden parent: %v", err)
	}
	t.Logf("provider.create.golden_ready_ms=%d", time.Since(createStarted).Milliseconds())
	defer removeMachineTimed(t, client, parent, "golden")

	prepareStarted := time.Now()
	if _, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc", boxdGoldenPrepareScript, "rundiff-golden",
		toolSHA, boxdFixtureRepository, boxdFixtureBaselineSHA, boxdFixtureCandidateSHA,
	}); err != nil {
		t.Fatalf("prepare golden parent: %v", err)
	}
	t.Logf("subject.golden_prepare_ms=%d", time.Since(prepareStarted).Milliseconds())

	changedResult, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc",
		`git -C /tmp/rundiff-subject diff --name-only "$1...$2"`,
		"rundiff-changed-paths", boxdFixtureBaselineSHA, boxdFixtureCandidateSHA,
	})
	if err != nil {
		t.Fatalf("resolve changed paths: %v", err)
	}
	changedPaths := nonEmptyLines(changedResult.Stdout)
	if !containsString(changedPaths, "server.mjs") {
		t.Fatalf("changed paths = %v, want server.mjs", changedPaths)
	}

	forkStarted := time.Now()
	pair, err := compute.ForkPair(
		ctx,
		client,
		parent.Name,
		baselineName,
		candidateName,
	)
	if err != nil {
		t.Fatalf("fork subject pair: %v", err)
	}
	t.Logf("provider.fork_pair_ready_ms=%d", time.Since(forkStarted).Milliseconds())
	defer cleanupPairTimed(t, client, pair)

	runID := "boxd-behavioral-" + proofID
	scenarioID := "node.http.widgets"
	spec := sensor.Spec{
		Adapter: "node",
		Mode:    "tool_owned_node_http",
		Runtime: "node",
	}

	baselineStarted := time.Now()
	baselineCapture := captureBoxdRole(
		t,
		ctx,
		client,
		pair.Baseline,
		"baseline",
		boxdFixtureBaselineSHA,
		runID,
		scenarioID,
	)
	t.Logf("scenario.baseline_capture_ms=%d", time.Since(baselineStarted).Milliseconds())
	if err := sensor.ValidateCapture(baselineCapture, sensor.ExpectedCapture{
		RunID:      runID,
		ScenarioID: scenarioID,
		Subject:    "github-pull-request",
		Label:      "baseline",
		SHA:        boxdFixtureBaselineSHA,
		Spec:       spec,
	}); err != nil {
		t.Fatalf("validate baseline capture: %v", err)
	}

	candidateStarted := time.Now()
	candidateCapture := captureBoxdRole(
		t,
		ctx,
		client,
		pair.Candidate,
		"candidate",
		boxdFixtureCandidateSHA,
		runID,
		scenarioID,
	)
	t.Logf("scenario.candidate_capture_ms=%d", time.Since(candidateStarted).Milliseconds())
	if err := sensor.ValidateCapture(candidateCapture, sensor.ExpectedCapture{
		RunID:      runID,
		ScenarioID: scenarioID,
		Subject:    "github-pull-request",
		Label:      "candidate",
		SHA:        boxdFixtureCandidateSHA,
		Spec:       spec,
	}); err != nil {
		t.Fatalf("validate candidate capture: %v", err)
	}

	baselineObject := decodeCaptureObject(t, baselineCapture)
	candidateObject := decodeCaptureObject(t, candidateCapture)
	if baselineObject["status"] != "passed" || baselineObject["http_status"] != float64(200) {
		t.Fatalf("baseline capture status/http = %v/%v, want passed/200", baselineObject["status"], baselineObject["http_status"])
	}
	if candidateObject["status"] != "failed" || candidateObject["http_status"] != float64(500) {
		t.Fatalf("candidate capture status/http = %v/%v, want failed/500", candidateObject["status"], candidateObject["http_status"])
	}

	compareStarted := time.Now()
	payloadObject, err := comparison.Pair(baselineObject, candidateObject, changedPaths)
	if err != nil {
		t.Fatalf("compare captures: %v", err)
	}
	payload, err := json.Marshal(payloadObject)
	if err != nil {
		t.Fatalf("marshal behavioral diff: %v", err)
	}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       payload,
	}
	if err := result.Validate(); err != nil {
		t.Fatalf("validate Result v1: %v", err)
	}
	t.Logf("comparison.behavioral_diff_ms=%d", time.Since(compareStarted).Milliseconds())

	productResult, ok := payloadObject["result"].(map[string]any)
	if !ok {
		t.Fatalf("behavioral diff result missing: %#v", payloadObject["result"])
	}
	if productResult["decision"] != "regression" {
		t.Fatalf("decision = %v, want regression", productResult["decision"])
	}
	if productResult["merge_recommendation"] != "block" {
		t.Fatalf("merge_recommendation = %v, want block", productResult["merge_recommendation"])
	}
	if !hasBlockingRuntimeError(productResult["findings"]) {
		t.Fatalf("findings = %#v, want blocking NEW_RUNTIME_ERROR", productResult["findings"])
	}

	t.Log("product.behavioral_diff=block")
	t.Log("product.finding=NEW_RUNTIME_ERROR")
	t.Logf("execution.total_ms=%d", time.Since(totalStarted).Milliseconds())
}

func captureBoxdRole(
	t *testing.T,
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	label string,
	sha string,
	runID string,
	scenarioID string,
) []byte {
	t.Helper()

	result, err := execBoxdOK(ctx, client, machine, []string{
		"bash", "-lc", boxdRoleCaptureScript, "rundiff-role",
		sha, label, runID, scenarioID,
	})
	if err != nil {
		t.Fatalf("capture %s: %v", label, err)
	}
	body := []byte(strings.TrimSpace(result.Stdout))
	if !json.Valid(body) {
		t.Fatalf("capture %s returned invalid JSON: %s", label, result.Stdout)
	}
	return body
}

func execBoxdOK(
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	argv []string,
) (compute.ExecResult, error) {
	result, err := client.Exec(ctx, machine, argv)
	if err != nil {
		return compute.ExecResult{}, err
	}
	if result.ExitCode != 0 {
		return compute.ExecResult{}, fmt.Errorf(
			"remote command exited with code %d: %s",
			result.ExitCode,
			strings.TrimSpace(result.Stderr),
		)
	}
	return result, nil
}

func decodeCaptureObject(t *testing.T, body []byte) map[string]any {
	t.Helper()

	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatalf("decode capture: %v", err)
	}
	return result
}

func nonEmptyLines(value string) []string {
	var result []string
	for _, line := range strings.Split(value, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			result = append(result, line)
		}
	}
	return result
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func hasBlockingRuntimeError(raw any) bool {
	findings, _ := raw.([]any)
	for _, item := range findings {
		finding, _ := item.(map[string]any)
		if finding["reason_code"] == "NEW_RUNTIME_ERROR" &&
			finding["finding_severity"] == "BLOCKING" &&
			finding["signal"] == "errors" {
			return true
		}
	}
	return false
}

func cleanupPairTimed(t *testing.T, client compute.Provider, pair compute.Pair) {
	t.Helper()

	started := time.Now()
	cleanupPair(t, client, pair)
	t.Logf("provider.cleanup.pair_ms=%d", time.Since(started).Milliseconds())
}

func removeMachineTimed(t *testing.T, client compute.Provider, machine compute.Machine, role string) {
	t.Helper()

	started := time.Now()
	removeMachine(t, client, machine)
	t.Logf("provider.cleanup.%s_ms=%d", role, time.Since(started).Milliseconds())
}

const boxdGoldenPrepareScript = `set -euo pipefail

tool_sha="$1"
repository="$2"
baseline_sha="$3"
candidate_sha="$4"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
  sudo systemctl start docker
fi
docker_cmd info >/dev/null

rm -rf /tmp/rundiff-subject
git clone --quiet "$repository" /tmp/rundiff-subject
git -C /tmp/rundiff-subject checkout --detach "$baseline_sha" >&2
git -C /tmp/rundiff-subject cat-file -e "$candidate_sha^{commit}"

cd /tmp/rundiff-subject
npm ci --no-audit --no-fund >&2

curl -fsSL "https://raw.githubusercontent.com/rundiff-hq/rundiff/${tool_sha}/script/rundiff_capture_node.mjs" \
  -o /tmp/rundiff_capture_node.mjs
node --check /tmp/rundiff_capture_node.mjs

docker_cmd pull postgres:16-alpine >&2
`

const boxdRoleCaptureScript = `set -euo pipefail

sha="$1"
label="$2"
run_id="$3"
scenario_id="$4"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

cd /tmp/rundiff-subject
git checkout --detach "$sha" >&2

docker_cmd rm -f rundiff-postgres >/dev/null 2>&1 || true
docker_cmd run -d \
  --name rundiff-postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=rundiff_bridge \
  -p 127.0.0.1:5432:5432 \
  postgres:16-alpine >&2

cleanup() {
  if [[ -n "${subject_pid:-}" ]]; then
    kill "$subject_pid" >/dev/null 2>&1 || true
  fi
  docker_cmd rm -f rundiff-postgres >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 80); do
  if docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >&2

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

cat /tmp/rundiff-capture.json
`
