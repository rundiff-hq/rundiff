package boxd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/comparison"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/sensor"
)

type productPathTiming struct {
	ForkPairReadyMS          int64 `json:"fork_pair_ready_ms"`
	InheritedPostgresReadyMS int64 `json:"inherited_postgres_ready_ms,omitempty"`
	BaselineCaptureMS        int64 `json:"baseline_capture_ms"`
	CandidateCaptureMS       int64 `json:"candidate_capture_ms"`
	ComparisonMS             int64 `json:"comparison_ms"`
	CleanupMS                int64 `json:"cleanup_ms"`
	TotalMS                  int64 `json:"total_ms"`
}

type productPathBenchmarkSample struct {
	Sample     int               `json:"sample"`
	First      string            `json:"first"`
	Current    productPathTiming `json:"current"`
	PreRunning productPathTiming `json:"pre_running"`
}

type productPathBenchmarkReport struct {
	SchemaVersion string                       `json:"schema_version"`
	Fixture       string                       `json:"fixture"`
	BaselineSHA   string                       `json:"baseline_sha"`
	CandidateSHA  string                       `json:"candidate_sha"`
	Samples       []productPathBenchmarkSample `json:"samples"`
	Summary       map[string]any               `json:"summary"`
}

func TestLivePreRunningPostgresBehavioralDiffBenchmark(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the pre-running PostgreSQL product benchmark")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the pre-running PostgreSQL product benchmark")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the pre-running PostgreSQL product benchmark")
	}
	toolSHA := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_TOOL_SHA"))
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for the pre-running PostgreSQL product benchmark")
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

	ctx, cancel := context.WithTimeout(context.Background(), 14*time.Minute)
	defer cancel()

	currentParent, err := client.Create(ctx, "rundiff-bcur-"+proofID, true)
	if err != nil {
		t.Fatalf("create current-path golden: %v", err)
	}
	defer removeMachine(t, client, currentParent)

	preRunningParent, err := client.Create(ctx, "rundiff-bpre-"+proofID, true)
	if err != nil {
		t.Fatalf("create pre-running golden: %v", err)
	}
	defer removeMachine(t, client, preRunningParent)

	prepareGolden := func(machine compute.Machine, preRunning bool) int64 {
		started := time.Now()
		if _, prepareErr := execBoxdOK(ctx, client, machine, []string{
			"bash", "-lc", boxdGoldenPrepareScript, "rundiff-golden",
			toolSHA, boxdFixtureRepository, boxdFixtureBaselineSHA, boxdFixtureCandidateSHA,
		}); prepareErr != nil {
			t.Fatalf("prepare golden %q: %v", machine.Name, prepareErr)
		}
		if preRunning {
			if _, startErr := execBoxdOK(ctx, client, machine, []string{
				"bash", "-lc", preRunningProductPostgresScript,
			}); startErr != nil {
				t.Fatalf("start PostgreSQL in golden %q: %v", machine.Name, startErr)
			}
		}
		return time.Since(started).Milliseconds()
	}

	currentPrepareMS := prepareGolden(currentParent, false)
	preRunningPrepareMS := prepareGolden(preRunningParent, true)
	t.Logf("product_benchmark.current_golden_prepare_ms=%d", currentPrepareMS)
	t.Logf("product_benchmark.pre_running_golden_prepare_ms=%d", preRunningPrepareMS)

	preRunningStartedAt := postgresContainerStartedAt(
		t,
		ctx,
		client,
		preRunningParent,
	)

	changedResult, err := execBoxdOK(ctx, client, currentParent, []string{
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

	const sampleCount = 5
	samples := make([]productPathBenchmarkSample, 0, sampleCount)
	currentTotals := make([]int64, 0, sampleCount)
	preRunningTotals := make([]int64, 0, sampleCount)
	currentCaptures := make([]int64, 0, sampleCount)
	preRunningCaptures := make([]int64, 0, sampleCount)

	for sample := 1; sample <= sampleCount; sample++ {
		runCurrent := func() productPathTiming {
			return runProductPathSample(
				t,
				ctx,
				client,
				currentParent,
				sample,
				proofID,
				"current",
				changedPaths,
				"",
			)
		}
		runPreRunning := func() productPathTiming {
			return runProductPathSample(
				t,
				ctx,
				client,
				preRunningParent,
				sample,
				proofID,
				"pre",
				changedPaths,
				preRunningStartedAt,
			)
		}

		var first string
		var currentTiming productPathTiming
		var preRunningTiming productPathTiming
		if sample%2 == 1 {
			first = "current"
			currentTiming = runCurrent()
			preRunningTiming = runPreRunning()
		} else {
			first = "pre_running"
			preRunningTiming = runPreRunning()
			currentTiming = runCurrent()
		}

		samples = append(samples, productPathBenchmarkSample{
			Sample:     sample,
			First:      first,
			Current:    currentTiming,
			PreRunning: preRunningTiming,
		})
		currentTotals = append(currentTotals, currentTiming.TotalMS)
		preRunningTotals = append(preRunningTotals, preRunningTiming.TotalMS)
		currentCaptures = append(
			currentCaptures,
			currentTiming.BaselineCaptureMS+currentTiming.CandidateCaptureMS,
		)
		preRunningCaptures = append(
			preRunningCaptures,
			preRunningTiming.BaselineCaptureMS+preRunningTiming.CandidateCaptureMS,
		)

		t.Logf(
			"product_benchmark.sample=%d first=%s current_total_ms=%d pre_running_total_ms=%d current_capture_ms=%d pre_running_capture_ms=%d",
			sample,
			first,
			currentTiming.TotalMS,
			preRunningTiming.TotalMS,
			currentTiming.BaselineCaptureMS+currentTiming.CandidateCaptureMS,
			preRunningTiming.BaselineCaptureMS+preRunningTiming.CandidateCaptureMS,
		)
	}

	if count := strings.TrimSpace(postgresQuery(
		t,
		ctx,
		client,
		preRunningParent,
		"SELECT count(*) FROM rundiff_product_isolation;",
	)); count != "0" {
		t.Fatalf("pre-running golden isolation markers = %s, want 0", count)
	}

	currentMedian := medianInt64(currentTotals)
	preRunningMedian := medianInt64(preRunningTotals)
	currentCaptureMedian := medianInt64(currentCaptures)
	preRunningCaptureMedian := medianInt64(preRunningCaptures)

	t.Logf("product_benchmark.current_total_median_ms=%d", currentMedian)
	t.Logf("product_benchmark.pre_running_total_median_ms=%d", preRunningMedian)
	t.Logf("product_benchmark.current_capture_median_ms=%d", currentCaptureMedian)
	t.Logf("product_benchmark.pre_running_capture_median_ms=%d", preRunningCaptureMedian)
	if preRunningMedian > 0 {
		t.Logf(
			"product_benchmark.total_speedup=%.3f",
			float64(currentMedian)/float64(preRunningMedian),
		)
	}
	if preRunningCaptureMedian > 0 {
		t.Logf(
			"product_benchmark.capture_speedup=%.3f",
			float64(currentCaptureMedian)/float64(preRunningCaptureMedian),
		)
	}

	report := productPathBenchmarkReport{
		SchemaVersion: "1",
		Fixture:       "rundiff-hq/example-node-express-postgres",
		BaselineSHA:   boxdFixtureBaselineSHA,
		CandidateSHA:  boxdFixtureCandidateSHA,
		Samples:       samples,
		Summary: map[string]any{
			"current_golden_prepare_ms":            currentPrepareMS,
			"pre_running_golden_prepare_ms":        preRunningPrepareMS,
			"current_total_median_ms":              currentMedian,
			"pre_running_total_median_ms":          preRunningMedian,
			"current_capture_median_ms":            currentCaptureMedian,
			"pre_running_capture_median_ms":        preRunningCaptureMedian,
			"current_over_pre_running_total_ratio": ratio(currentMedian, preRunningMedian),
			"current_over_pre_running_capture_ratio": ratio(
				currentCaptureMedian,
				preRunningCaptureMedian,
			),
		},
	}
	writeProductBenchmarkReport(t, report)

	t.Log("product_benchmark.pre_running_postgres=ok")
}

func runProductPathSample(
	t *testing.T,
	ctx context.Context,
	client *PairSDK,
	parent compute.Machine,
	sample int,
	proofID string,
	mode string,
	changedPaths []string,
	inheritedStartedAt string,
) productPathTiming {
	t.Helper()

	totalStarted := time.Now()
	baselineName := fmt.Sprintf("rundiff-%sb%d-%s", mode, sample, proofID)
	candidateName := fmt.Sprintf("rundiff-%sc%d-%s", mode, sample, proofID)

	forkStarted := time.Now()
	pair, err := compute.ForkPair(
		ctx,
		client,
		parent.Name,
		baselineName,
		candidateName,
	)
	if err != nil {
		t.Fatalf("%s sample %d fork pair: %v", mode, sample, err)
	}
	timing := productPathTiming{
		ForkPairReadyMS: time.Since(forkStarted).Milliseconds(),
	}

	cleaned := false
	defer func() {
		if !cleaned {
			cleanupPair(t, client, pair)
		}
	}()

	if inheritedStartedAt != "" {
		readyStarted := time.Now()
		assertInheritedProductPostgres(
			t,
			ctx,
			client,
			pair,
			inheritedStartedAt,
		)
		timing.InheritedPostgresReadyMS = time.Since(readyStarted).Milliseconds()
	}

	runID := fmt.Sprintf("boxd-product-%s-%d-%s", mode, sample, proofID)
	scenarioID := "node.http.widgets"
	spec := sensor.Spec{
		Adapter: "node",
		Mode:    "tool_owned_node_http",
		Runtime: "node",
	}

	baselineStarted := time.Now()
	var baselineCapture []byte
	if inheritedStartedAt == "" {
		baselineCapture = captureBoxdRole(
			t,
			ctx,
			client,
			pair.Baseline,
			"baseline",
			boxdFixtureBaselineSHA,
			runID,
			scenarioID,
		)
	} else {
		baselineCapture = captureBoxdRoleInheritedPostgres(
			t,
			ctx,
			client,
			pair.Baseline,
			"baseline",
			boxdFixtureBaselineSHA,
			runID,
			scenarioID,
		)
	}
	timing.BaselineCaptureMS = time.Since(baselineStarted).Milliseconds()

	candidateStarted := time.Now()
	var candidateCapture []byte
	if inheritedStartedAt == "" {
		candidateCapture = captureBoxdRole(
			t,
			ctx,
			client,
			pair.Candidate,
			"candidate",
			boxdFixtureCandidateSHA,
			runID,
			scenarioID,
		)
	} else {
		candidateCapture = captureBoxdRoleInheritedPostgres(
			t,
			ctx,
			client,
			pair.Candidate,
			"candidate",
			boxdFixtureCandidateSHA,
			runID,
			scenarioID,
		)
	}
	timing.CandidateCaptureMS = time.Since(candidateStarted).Milliseconds()

	compareStarted := time.Now()
	assertProductBehavioralDiff(
		t,
		baselineCapture,
		candidateCapture,
		changedPaths,
		runID,
		scenarioID,
		spec,
	)
	timing.ComparisonMS = time.Since(compareStarted).Milliseconds()

	if inheritedStartedAt != "" {
		baselineMarker := fmt.Sprintf("baseline-%d", sample)
		candidateMarker := fmt.Sprintf("candidate-%d", sample)
		postgresExec(
			t,
			ctx,
			client,
			pair.Baseline,
			fmt.Sprintf(
				"INSERT INTO rundiff_product_isolation(role) VALUES ('%s'); CHECKPOINT;",
				baselineMarker,
			),
		)
		if count := strings.TrimSpace(postgresQuery(
			t,
			ctx,
			client,
			pair.Candidate,
			fmt.Sprintf(
				"SELECT count(*) FROM rundiff_product_isolation WHERE role = '%s';",
				baselineMarker,
			),
		)); count != "0" {
			t.Fatalf("candidate saw baseline DB marker %q", baselineMarker)
		}
		postgresExec(
			t,
			ctx,
			client,
			pair.Candidate,
			fmt.Sprintf(
				"INSERT INTO rundiff_product_isolation(role) VALUES ('%s'); CHECKPOINT;",
				candidateMarker,
			),
		)
		if count := strings.TrimSpace(postgresQuery(
			t,
			ctx,
			client,
			pair.Baseline,
			fmt.Sprintf(
				"SELECT count(*) FROM rundiff_product_isolation WHERE role = '%s';",
				candidateMarker,
			),
		)); count != "0" {
			t.Fatalf("baseline saw candidate DB marker %q", candidateMarker)
		}
	}

	cleanupStarted := time.Now()
	cleanupPair(t, client, pair)
	cleaned = true
	timing.CleanupMS = time.Since(cleanupStarted).Milliseconds()
	timing.TotalMS = time.Since(totalStarted).Milliseconds()
	return timing
}

func assertInheritedProductPostgres(
	t *testing.T,
	ctx context.Context,
	client *PairSDK,
	pair compute.Pair,
	parentStartedAt string,
) {
	t.Helper()

	type readyResult struct {
		role      string
		startedAt string
		err       error
	}
	ready := make(chan readyResult, 2)
	go func() {
		err := waitRunningPostgres(ctx, client.primary, pair.Baseline)
		var startedAt string
		if err == nil {
			startedAt, err = postgresContainerStartedAtWithProvider(
				ctx,
				client.primary,
				pair.Baseline,
			)
		}
		ready <- readyResult{role: "baseline", startedAt: startedAt, err: err}
	}()
	go func() {
		err := waitRunningPostgres(ctx, client.secondary, pair.Candidate)
		var startedAt string
		if err == nil {
			startedAt, err = postgresContainerStartedAtWithProvider(
				ctx,
				client.secondary,
				pair.Candidate,
			)
		}
		ready <- readyResult{role: "candidate", startedAt: startedAt, err: err}
	}()

	for range 2 {
		result := <-ready
		if result.err != nil {
			t.Fatalf("%s inherited product PostgreSQL: %v", result.role, result.err)
		}
		if result.startedAt != parentStartedAt {
			t.Fatalf(
				"%s product PostgreSQL StartedAt = %q, parent = %q",
				result.role,
				result.startedAt,
				parentStartedAt,
			)
		}
	}
}

func captureBoxdRoleInheritedPostgres(
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
		"bash", "-lc", boxdRoleCaptureInheritedPostgresScript, "rundiff-role",
		sha, label, runID, scenarioID,
	})
	if err != nil {
		t.Fatalf("capture inherited-PostgreSQL %s: %v", label, err)
	}
	body := []byte(strings.TrimSpace(result.Stdout))
	if !json.Valid(body) {
		t.Fatalf(
			"capture inherited-PostgreSQL %s returned invalid JSON: %s",
			label,
			result.Stdout,
		)
	}
	return body
}

func assertProductBehavioralDiff(
	t *testing.T,
	baselineCapture []byte,
	candidateCapture []byte,
	changedPaths []string,
	runID string,
	scenarioID string,
	spec sensor.Spec,
) {
	t.Helper()

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
	if baselineObject["status"] != "passed" ||
		baselineObject["http_status"] != float64(200) {
		t.Fatalf(
			"baseline capture status/http = %v/%v, want passed/200",
			baselineObject["status"],
			baselineObject["http_status"],
		)
	}
	if candidateObject["status"] != "failed" ||
		candidateObject["http_status"] != float64(500) {
		t.Fatalf(
			"candidate capture status/http = %v/%v, want failed/500",
			candidateObject["status"],
			candidateObject["http_status"],
		)
	}

	payloadObject, err := comparison.Pair(
		baselineObject,
		candidateObject,
		changedPaths,
	)
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

	productResult, ok := payloadObject["result"].(map[string]any)
	if !ok {
		t.Fatalf("behavioral diff result missing: %#v", payloadObject["result"])
	}
	if productResult["decision"] != "regression" {
		t.Fatalf("decision = %v, want regression", productResult["decision"])
	}
	if productResult["merge_recommendation"] != "block" {
		t.Fatalf(
			"merge_recommendation = %v, want block",
			productResult["merge_recommendation"],
		)
	}
	if !hasBlockingRuntimeError(productResult["findings"]) {
		t.Fatalf(
			"findings = %#v, want blocking NEW_RUNTIME_ERROR",
			productResult["findings"],
		)
	}
}

func writeProductBenchmarkReport(
	t *testing.T,
	report productPathBenchmarkReport,
) {
	t.Helper()

	path := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_PRODUCT_BENCHMARK_OUTPUT"))
	if path == "" {
		return
	}
	body, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatalf("marshal product benchmark report: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("create product benchmark output directory: %v", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatalf("write product benchmark report: %v", err)
	}
}

func ratio(numerator int64, denominator int64) float64 {
	if denominator == 0 {
		return 0
	}
	return float64(numerator) / float64(denominator)
}

const preRunningProductPostgresScript = `set -euo pipefail

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

docker_cmd rm -f rundiff-postgres >/dev/null 2>&1 || true
docker_cmd run -d \
  --name rundiff-postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=rundiff_bridge \
  -p 127.0.0.1:5432:5432 \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 80); do
  if docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >/dev/null

docker_cmd exec -i rundiff-postgres psql -v ON_ERROR_STOP=1 -U postgres -d rundiff_bridge >/dev/null <<'SQL'
CREATE TABLE rundiff_product_isolation (
  role text PRIMARY KEY
);
CHECKPOINT;
SQL
`

const boxdRoleCaptureInheritedPostgresScript = `set -euo pipefail

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

docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >&2

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
