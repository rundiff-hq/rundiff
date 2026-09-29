package boxd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/comparison"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/sensor"
)

type behavioralDBMode string

const (
	behavioralDBCurrent   behavioralDBMode = "post_fork_start"
	behavioralDBInherited behavioralDBMode = "inherited_running"
)

type behavioralDBSample struct {
	Mode                     behavioralDBMode `json:"mode"`
	Sample                   int              `json:"sample"`
	SequencePosition         int              `json:"sequence_position"`
	PairForkReadyMS          int64            `json:"pair_fork_ready_ms"`
	InheritedPostgresReadyMS int64            `json:"inherited_postgres_ready_ms,omitempty"`
	BaselineCaptureMS        int64            `json:"baseline_capture_ms"`
	CandidateCaptureMS       int64            `json:"candidate_capture_ms"`
	ComparisonMS             int64            `json:"comparison_ms"`
	CleanupMS                int64            `json:"cleanup_ms"`
	TotalMS                  int64            `json:"total_ms"`
	Decision                 string           `json:"decision"`
	Finding                  string           `json:"finding"`
}

type behavioralDBSummary struct {
	Count       int   `json:"count"`
	MedianMS    int64 `json:"median_ms"`
	P95MS       int64 `json:"p95_ms"`
	MinMS       int64 `json:"min_ms"`
	MaxMS       int64 `json:"max_ms"`
}

type behavioralDBBenchmarkReport struct {
	SchemaVersion string                         `json:"schema_version"`
	Fixture       string                         `json:"fixture"`
	BaselineSHA   string                         `json:"baseline_sha"`
	CandidateSHA  string                         `json:"candidate_sha"`
	Samples       []behavioralDBSample           `json:"samples"`
	Summary       map[string]behavioralDBSummary `json:"summary"`
}

func TestLiveBehavioralDiffInheritedPostgresBenchmark(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live inherited PostgreSQL benchmark")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live inherited PostgreSQL benchmark")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live inherited PostgreSQL benchmark")
	}
	toolSHA := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_TOOL_SHA"))
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for the live inherited PostgreSQL benchmark")
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

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()

	currentParent := prepareBehavioralBenchmarkGolden(
		t,
		ctx,
		client,
		"rundiff-bc-"+proofID,
		toolSHA,
		false,
	)
	defer removeMachine(t, client, currentParent)

	inheritedParent := prepareBehavioralBenchmarkGolden(
		t,
		ctx,
		client,
		"rundiff-bi-"+proofID,
		toolSHA,
		true,
	)
	defer removeMachine(t, client, inheritedParent)

	parentStartedAt := postgresContainerStartedAt(
		t,
		ctx,
		client,
		inheritedParent,
	)

	const samplesPerMode = 5
	samples := make([]behavioralDBSample, 0, samplesPerMode*2)

	for sample := 1; sample <= samplesPerMode; sample++ {
		if sample%2 == 1 {
			samples = append(samples, runBehavioralDBSample(
				t, ctx, client, currentParent, "", behavioralDBCurrent, sample, 1, proofID,
			))
			samples = append(samples, runBehavioralDBSample(
				t, ctx, client, inheritedParent, parentStartedAt, behavioralDBInherited, sample, 2, proofID,
			))
		} else {
			samples = append(samples, runBehavioralDBSample(
				t, ctx, client, inheritedParent, parentStartedAt, behavioralDBInherited, sample, 1, proofID,
			))
			samples = append(samples, runBehavioralDBSample(
				t, ctx, client, currentParent, "", behavioralDBCurrent, sample, 2, proofID,
			))
		}
	}

	report := behavioralDBBenchmarkReport{
		SchemaVersion: "1",
		Fixture:       "rundiff-hq/example-node-express-postgres",
		BaselineSHA:   boxdFixtureBaselineSHA,
		CandidateSHA:  boxdFixtureCandidateSHA,
		Samples:       samples,
		Summary: map[string]behavioralDBSummary{
			string(behavioralDBCurrent): summarizeBehavioralDBSamples(samples, behavioralDBCurrent),
			string(behavioralDBInherited): summarizeBehavioralDBSamples(
				samples,
				behavioralDBInherited,
			),
		},
	}

	currentSummary := report.Summary[string(behavioralDBCurrent)]
	inheritedSummary := report.Summary[string(behavioralDBInherited)]
	t.Logf(
		"behavioral_db_benchmark.current_median_ms=%d",
		currentSummary.MedianMS,
	)
	t.Logf(
		"behavioral_db_benchmark.inherited_median_ms=%d",
		inheritedSummary.MedianMS,
	)
	if inheritedSummary.MedianMS > 0 {
		t.Logf(
			"behavioral_db_benchmark.speedup=%.3f",
			float64(currentSummary.MedianMS)/float64(inheritedSummary.MedianMS),
		)
	}

	writeBehavioralDBBenchmarkReport(t, report)
}

func prepareBehavioralBenchmarkGolden(
	t *testing.T,
	ctx context.Context,
	client *PairSDK,
	name string,
	toolSHA string,
	startPostgres bool,
) compute.Machine {
	t.Helper()

	parent, err := client.Create(ctx, name, true)
	if err != nil {
		t.Fatalf("create benchmark golden %q: %v", name, err)
	}

	if _, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc", boxdGoldenPrepareScript, "rundiff-golden",
		toolSHA, boxdFixtureRepository, boxdFixtureBaselineSHA, boxdFixtureCandidateSHA,
	}); err != nil {
		removeMachine(t, client, parent)
		t.Fatalf("prepare benchmark golden %q: %v", name, err)
	}

	if startPostgres {
		if _, err := execBoxdOK(ctx, client, parent, []string{
			"bash", "-lc", inheritedBehavioralPostgresPrepareScript,
		}); err != nil {
			removeMachine(t, client, parent)
			t.Fatalf("start inherited PostgreSQL in golden %q: %v", name, err)
		}
		if err := waitRunningPostgres(ctx, client, parent); err != nil {
			removeMachine(t, client, parent)
			t.Fatalf("inherited PostgreSQL golden %q not ready: %v", name, err)
		}
	}

	return parent
}

func runBehavioralDBSample(
	t *testing.T,
	ctx context.Context,
	client *PairSDK,
	parent compute.Machine,
	parentStartedAt string,
	mode behavioralDBMode,
	sample int,
	sequencePosition int,
	proofID string,
) behavioralDBSample {
	t.Helper()

	totalStarted := time.Now()
	prefix := "cur"
	if mode == behavioralDBInherited {
		prefix = "inh"
	}
	baselineName := fmt.Sprintf("rundiff-%s-b%d-%s", prefix, sample, proofID)
	candidateName := fmt.Sprintf("rundiff-%s-c%d-%s", prefix, sample, proofID)

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
	pairForkMS := time.Since(forkStarted).Milliseconds()

	cleanupStarted := time.Time{}
	cleanupMS := int64(0)
	cleaned := false
	defer func() {
		if cleaned {
			return
		}
		cleanupPair(t, client, pair)
	}()

	inheritedReadyMS := int64(0)
	if mode == behavioralDBInherited {
		readyStarted := time.Now()
		assertInheritedBehavioralPostgres(
			t,
			ctx,
			client,
			pair,
			parentStartedAt,
		)
		inheritedReadyMS = time.Since(readyStarted).Milliseconds()
	}

	runID := fmt.Sprintf(
		"boxd-behavioral-db-%s-%d-%s",
		prefix,
		sample,
		proofID,
	)
	scenarioID := "node.http.widgets"

	baselineStarted := time.Now()
	var baselineCapture []byte
	if mode == behavioralDBInherited {
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
	} else {
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
	}
	baselineMS := time.Since(baselineStarted).Milliseconds()

	candidateStarted := time.Now()
	var candidateCapture []byte
	if mode == behavioralDBInherited {
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
	} else {
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
	}
	candidateMS := time.Since(candidateStarted).Milliseconds()

	validateBehavioralBenchmarkCapture(
		t,
		baselineCapture,
		runID,
		scenarioID,
		"baseline",
		boxdFixtureBaselineSHA,
		"passed",
		200,
	)
	validateBehavioralBenchmarkCapture(
		t,
		candidateCapture,
		runID,
		scenarioID,
		"candidate",
		boxdFixtureCandidateSHA,
		"failed",
		500,
	)

	compareStarted := time.Now()
	assertBehavioralBenchmarkResult(
		t,
		baselineCapture,
		candidateCapture,
	)
	comparisonMS := time.Since(compareStarted).Milliseconds()

	cleanupStarted = time.Now()
	cleanupPair(t, client, pair)
	cleanupMS = time.Since(cleanupStarted).Milliseconds()
	cleaned = true

	result := behavioralDBSample{
		Mode:                     mode,
		Sample:                   sample,
		SequencePosition:         sequencePosition,
		PairForkReadyMS:          pairForkMS,
		InheritedPostgresReadyMS: inheritedReadyMS,
		BaselineCaptureMS:        baselineMS,
		CandidateCaptureMS:       candidateMS,
		ComparisonMS:             comparisonMS,
		CleanupMS:                cleanupMS,
		TotalMS:                  time.Since(totalStarted).Milliseconds(),
		Decision:                 "block",
		Finding:                  "NEW_RUNTIME_ERROR",
	}
	t.Logf(
		"behavioral_db_benchmark.sample=%d mode=%s position=%d fork_ms=%d inherited_ready_ms=%d baseline_ms=%d candidate_ms=%d compare_ms=%d cleanup_ms=%d total_ms=%d",
		sample,
		mode,
		sequencePosition,
		pairForkMS,
		inheritedReadyMS,
		baselineMS,
		candidateMS,
		comparisonMS,
		cleanupMS,
		result.TotalMS,
	)
	return result
}

func assertInheritedBehavioralPostgres(
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
	results := make(chan readyResult, 2)

	go func() {
		err := waitRunningPostgres(ctx, client.primary, pair.Baseline)
		startedAt := ""
		if err == nil {
			startedAt, err = postgresContainerStartedAtWithProvider(
				ctx,
				client.primary,
				pair.Baseline,
			)
		}
		results <- readyResult{role: "baseline", startedAt: startedAt, err: err}
	}()
	go func() {
		err := waitRunningPostgres(ctx, client.secondary, pair.Candidate)
		startedAt := ""
		if err == nil {
			startedAt, err = postgresContainerStartedAtWithProvider(
				ctx,
				client.secondary,
				pair.Candidate,
			)
		}
		results <- readyResult{role: "candidate", startedAt: startedAt, err: err}
	}()

	for range 2 {
		result := <-results
		if result.err != nil {
			t.Fatalf("%s inherited PostgreSQL not ready: %v", result.role, result.err)
		}
		if result.startedAt != parentStartedAt {
			t.Fatalf(
				"%s PostgreSQL StartedAt = %q, parent = %q",
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
		"bash", "-lc", boxdInheritedPostgresRoleCaptureScript, "rundiff-role",
		sha, label, runID, scenarioID,
	})
	if err != nil {
		t.Fatalf("capture inherited PostgreSQL %s: %v", label, err)
	}
	body := []byte(strings.TrimSpace(result.Stdout))
	if !json.Valid(body) {
		t.Fatalf(
			"capture inherited PostgreSQL %s returned invalid JSON: %s",
			label,
			result.Stdout,
		)
	}
	return body
}

func validateBehavioralBenchmarkCapture(
	t *testing.T,
	body []byte,
	runID string,
	scenarioID string,
	label string,
	sha string,
	wantStatus string,
	wantHTTP int,
) {
	t.Helper()

	spec := sensor.Spec{
		Adapter: "node",
		Mode:    "tool_owned_node_http",
		Runtime: "node",
	}
	if err := sensor.ValidateCapture(body, sensor.ExpectedCapture{
		RunID:      runID,
		ScenarioID: scenarioID,
		Subject:    "github-pull-request",
		Label:      label,
		SHA:        sha,
		Spec:       spec,
	}); err != nil {
		t.Fatalf("validate %s capture: %v", label, err)
	}

	object := decodeCaptureObject(t, body)
	if object["status"] != wantStatus ||
		object["http_status"] != float64(wantHTTP) {
		t.Fatalf(
			"%s capture status/http = %v/%v, want %s/%d",
			label,
			object["status"],
			object["http_status"],
			wantStatus,
			wantHTTP,
		)
	}
}

func assertBehavioralBenchmarkResult(
	t *testing.T,
	baselineCapture []byte,
	candidateCapture []byte,
) {
	t.Helper()

	baselineObject := decodeCaptureObject(t, baselineCapture)
	candidateObject := decodeCaptureObject(t, candidateCapture)
	payloadObject, err := comparison.Pair(
		baselineObject,
		candidateObject,
		[]string{"server.mjs"},
	)
	if err != nil {
		t.Fatalf("compare benchmark captures: %v", err)
	}
	payload, err := json.Marshal(payloadObject)
	if err != nil {
		t.Fatalf("marshal benchmark Behavioral Diff: %v", err)
	}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       payload,
	}
	if err := result.Validate(); err != nil {
		t.Fatalf("validate benchmark Result v1: %v", err)
	}

	productResult, ok := payloadObject["result"].(map[string]any)
	if !ok {
		t.Fatalf("benchmark Behavioral Diff result missing")
	}
	if productResult["decision"] != "regression" ||
		productResult["merge_recommendation"] != "block" ||
		!hasBlockingRuntimeError(productResult["findings"]) {
		t.Fatalf("unexpected benchmark product result: %#v", productResult)
	}
}

func summarizeBehavioralDBSamples(
	samples []behavioralDBSample,
	mode behavioralDBMode,
) behavioralDBSummary {
	values := make([]int64, 0, 5)
	for _, sample := range samples {
		if sample.Mode == mode {
			values = append(values, sample.TotalMS)
		}
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	if len(values) == 0 {
		return behavioralDBSummary{}
	}
	p95Index := len(values) - 1
	return behavioralDBSummary{
		Count:    len(values),
		MedianMS: values[len(values)/2],
		P95MS:    values[p95Index],
		MinMS:    values[0],
		MaxMS:    values[len(values)-1],
	}
}

func writeBehavioralDBBenchmarkReport(
	t *testing.T,
	report behavioralDBBenchmarkReport,
) {
	t.Helper()

	path := strings.TrimSpace(
		os.Getenv("RUNDIFF_BOXD_BEHAVIORAL_DB_BENCHMARK_REPORT"),
	)
	if path == "" {
		path = filepath.Join(
			"tmp",
			"rundiff",
			"boxd-prerunning-postgres-benchmark.json",
		)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("create benchmark report directory: %v", err)
	}
	body, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatalf("marshal benchmark report: %v", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatalf("write benchmark report: %v", err)
	}
	t.Logf("behavioral_db_benchmark.report=%s", path)
}

const inheritedBehavioralPostgresPrepareScript = `set -euo pipefail

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
docker_cmd exec rundiff-postgres psql -v ON_ERROR_STOP=1 -U postgres -d rundiff_bridge -c 'CHECKPOINT' >/dev/null
`

const boxdInheritedPostgresRoleCaptureScript = `set -euo pipefail

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
