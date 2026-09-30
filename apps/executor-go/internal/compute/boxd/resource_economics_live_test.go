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

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

const resourceEconomicsMeasurementKind = "guest_observed_proxy_not_provider_billing"

type guestResourceSnapshot struct {
	CollectedAtUTC           string
	Stage                    string
	Role                     string
	Machine                  string
	GuestMemTotalBytes       int64
	GuestMemAvailableBytes   int64
	GuestMemUsedProxyBytes   int64
	ProcessRSSSumBytes       int64
	CgroupMemoryCurrentBytes *int64
	RootFSUsedBytes          int64
	RepoBytes                int64
	NodeModulesBytes         int64
	DockerRootBytes          *int64
	PostgresSizeRWBytes      *int64
	PostgresSizeRootFSBytes  *int64
	PostgresVolumeBytes      *int64
}

type resourceRoleEnvelope struct {
	Capture  json.RawMessage
	Resource guestResourceSnapshot
}

type resourceLifecycleSample struct {
	Sample               int
	ForkStartedAtUTC     string
	PairReadyAtUTC       string
	CaptureStartedAtUTC  string
	CaptureFinishedAtUTC string
	CleanupStartedAtUTC  string
	CleanupFinishedAtUTC string
	ForkReadyMS          int64
	BaselineRoleMS       int64
	CandidateRoleMS      int64
	RoleCriticalPathMS   int64
	CleanupMS            int64
	TotalMS              int64
	Baseline             guestResourceSnapshot
	Candidate            guestResourceSnapshot
	Decision             string
	Finding              string
}

type resourceMetricSummary struct {
	Count  int64
	Median int64
	Min    int64
	Max    int64
}

type resourceEconomicsSummary struct {
	ChildGuestMemUsedProxyBytes resourceMetricSummary
	ChildProcessRSSSumBytes     resourceMetricSummary
	ChildRootFSUsedBytes        resourceMetricSummary
	ChildPostgresVolumeBytes    resourceMetricSummary
	ChildPostgresSizeRWBytes    resourceMetricSummary
	ForkReadyMS                 resourceMetricSummary
	RoleCriticalPathMS          resourceMetricSummary
	CleanupMS                   resourceMetricSummary
}

type resourceEconomicsReport struct {
	SchemaVersion       string
	MeasurementKind     string
	BillingCaveat       string
	Fixture             string
	BaselineSHA         string
	CandidateSHA        string
	GoldenBeforeSamples guestResourceSnapshot
	GoldenAfterSamples  guestResourceSnapshot
	Samples             []resourceLifecycleSample
	Summary             resourceEconomicsSummary
}

func TestLiveBoxdResourceEconomicsTelemetry(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run Boxd resource economics telemetry")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for Boxd resource economics telemetry")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for Boxd resource economics telemetry")
	}
	toolSHA := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_TOOL_SHA"))
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for Boxd resource economics telemetry")
	}

	client, err := NewSessionPairSDK(
		"node",
		"sdkbridge/session.mjs",
		"sdkbridge/bridge.mjs",
	)
	if err != nil {
		t.Fatalf("start resource telemetry PairSDK: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close resource telemetry PairSDK: %v", closeErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()

	parent := prepareBehavioralBenchmarkGolden(
		t,
		ctx,
		client,
		"rundiff-re-"+proofID,
		toolSHA,
		true,
	)
	defer removeMachine(t, client, parent)

	installResourceTelemetryHelpers(t, ctx, client, parent, toolSHA)

	parentStartedAt := postgresContainerStartedAt(t, ctx, client, parent)
	goldenBefore := collectGuestResourceSnapshot(
		t,
		ctx,
		client,
		parent,
		"golden_before_samples",
		"golden",
		true,
	)

	const sampleCount = 5
	samples := make([]resourceLifecycleSample, 0, sampleCount)
	for sample := 1; sample <= sampleCount; sample++ {
		samples = append(samples, runResourceEconomicsSample(
			t,
			ctx,
			client,
			parent,
			parentStartedAt,
			sample,
			proofID,
		))
	}

	goldenAfter := collectGuestResourceSnapshot(
		t,
		ctx,
		client,
		parent,
		"golden_after_samples",
		"golden",
		true,
	)

	report := resourceEconomicsReport{
		SchemaVersion:       "1",
		MeasurementKind:     resourceEconomicsMeasurementKind,
		BillingCaveat:       "guest-observed /proc, filesystem and Docker measurements are resource proxies; they are not Boxd invoice counters",
		Fixture:             "rundiff-hq/example-node-express-postgres",
		BaselineSHA:         boxdFixtureBaselineSHA,
		CandidateSHA:        boxdFixtureCandidateSHA,
		GoldenBeforeSamples: goldenBefore,
		GoldenAfterSamples:  goldenAfter,
		Samples:             samples,
		Summary:             summarizeResourceEconomicsSamples(samples),
	}
	writeResourceEconomicsReport(t, report)

	t.Logf(
		"resource_economics.golden_mem_used_proxy_bytes=%d",
		goldenBefore.GuestMemUsedProxyBytes,
	)
	t.Logf(
		"resource_economics.golden_rootfs_used_bytes=%d",
		goldenBefore.RootFSUsedBytes,
	)
	if goldenBefore.DockerRootBytes != nil {
		t.Logf(
			"resource_economics.golden_docker_root_bytes=%d",
			*goldenBefore.DockerRootBytes,
		)
	}
	t.Logf(
		"resource_economics.child_mem_used_proxy_median_bytes=%d",
		report.Summary.ChildGuestMemUsedProxyBytes.Median,
	)
	t.Logf(
		"resource_economics.child_rss_median_bytes=%d",
		report.Summary.ChildProcessRSSSumBytes.Median,
	)
	t.Log("resource_economics.measurement_kind=" + resourceEconomicsMeasurementKind)
}

func installResourceTelemetryHelpers(
	t *testing.T,
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	toolSHA string,
) {
	t.Helper()

	base := "https://raw.githubusercontent.com/rundiff-hq/rundiff/" +
		toolSHA +
		"/apps/executor-go/internal/compute/boxd/testdata/"
	files := []struct {
		remote string
		url    string
	}{
		{
			remote: "/tmp/rundiff_resource_snapshot.py",
			url:    base + "resource_snapshot.py",
		},
		{
			remote: "/tmp/rundiff_resource_role_capture.sh",
			url:    base + "resource_role_capture.sh",
		},
	}
	for _, file := range files {
		if _, err := execBoxdOK(ctx, client, machine, []string{
			"curl", "-fsSL", file.url, "-o", file.remote,
		}); err != nil {
			t.Fatalf("download telemetry helper %q: %v", file.remote, err)
		}
		if _, err := execBoxdOK(ctx, client, machine, []string{
			"chmod", "0755", file.remote,
		}); err != nil {
			t.Fatalf("chmod telemetry helper %q: %v", file.remote, err)
		}
	}
	if _, err := execBoxdOK(ctx, client, machine, []string{
		"python3", "-m", "py_compile", "/tmp/rundiff_resource_snapshot.py",
	}); err != nil {
		t.Fatalf("compile resource snapshot helper: %v", err)
	}
	if _, err := execBoxdOK(ctx, client, machine, []string{
		"bash", "-n", "/tmp/rundiff_resource_role_capture.sh",
	}); err != nil {
		t.Fatalf("validate resource role helper: %v", err)
	}
}

func runResourceEconomicsSample(
	t *testing.T,
	ctx context.Context,
	client *PairSDK,
	parent compute.Machine,
	parentStartedAt string,
	sample int,
	proofID string,
) resourceLifecycleSample {
	t.Helper()

	totalStarted := time.Now()
	forkStartedAt := time.Now().UTC()
	forkStarted := time.Now()
	pair, err := compute.ForkPair(
		ctx,
		client,
		parent.Name,
		fmt.Sprintf("rundiff-re-b%d-%s", sample, proofID),
		fmt.Sprintf("rundiff-re-c%d-%s", sample, proofID),
	)
	if err != nil {
		t.Fatalf("resource sample %d fork pair: %v", sample, err)
	}
	pairReadyAt := time.Now().UTC()
	forkReadyMS := time.Since(forkStarted).Milliseconds()

	cleaned := false
	defer func() {
		if !cleaned {
			cleanupPair(t, client, pair)
		}
	}()

	runID := fmt.Sprintf("boxd-resource-%d-%s", sample, proofID)
	scenarioID := "node.http.widgets"
	captureStartedAt := time.Now().UTC()
	captures := runParallelRoleCaptures(
		ctx,
		func(roleCtx context.Context) ([]byte, error) {
			return captureBoxdRoleWithResourceTelemetry(
				roleCtx,
				client.primary,
				pair.Baseline,
				"baseline",
				boxdFixtureBaselineSHA,
				runID,
				scenarioID,
				parentStartedAt,
			)
		},
		func(roleCtx context.Context) ([]byte, error) {
			return captureBoxdRoleWithResourceTelemetry(
				roleCtx,
				client.secondary,
				pair.Candidate,
				"candidate",
				boxdFixtureCandidateSHA,
				runID,
				scenarioID,
				parentStartedAt,
			)
		},
	)
	captureFinishedAt := time.Now().UTC()
	if captures.Baseline.Err != nil || captures.Candidate.Err != nil {
		t.Fatalf(
			"resource sample %d capture errors baseline/candidate = %v/%v",
			sample,
			captures.Baseline.Err,
			captures.Candidate.Err,
		)
	}

	baselineEnvelope := decodeResourceRoleEnvelope(t, captures.Baseline.Body)
	candidateEnvelope := decodeResourceRoleEnvelope(t, captures.Candidate.Body)
	baselineEnvelope.Resource.Machine = pair.Baseline.Name
	candidateEnvelope.Resource.Machine = pair.Candidate.Name

	validateBehavioralBenchmarkCapture(
		t,
		baselineEnvelope.Capture,
		runID,
		scenarioID,
		"baseline",
		boxdFixtureBaselineSHA,
		"passed",
		200,
	)
	validateBehavioralBenchmarkCapture(
		t,
		candidateEnvelope.Capture,
		runID,
		scenarioID,
		"candidate",
		boxdFixtureCandidateSHA,
		"failed",
		500,
	)
	assertBehavioralBenchmarkResult(
		t,
		baselineEnvelope.Capture,
		candidateEnvelope.Capture,
	)

	cleanupStartedAt := time.Now().UTC()
	cleanupStarted := time.Now()
	cleanupPair(t, client, pair)
	cleanupMS := time.Since(cleanupStarted).Milliseconds()
	cleanupFinishedAt := time.Now().UTC()
	cleaned = true

	result := resourceLifecycleSample{
		Sample:               sample,
		ForkStartedAtUTC:     forkStartedAt.Format(time.RFC3339Nano),
		PairReadyAtUTC:       pairReadyAt.Format(time.RFC3339Nano),
		CaptureStartedAtUTC:  captureStartedAt.Format(time.RFC3339Nano),
		CaptureFinishedAtUTC: captureFinishedAt.Format(time.RFC3339Nano),
		CleanupStartedAtUTC:  cleanupStartedAt.Format(time.RFC3339Nano),
		CleanupFinishedAtUTC: cleanupFinishedAt.Format(time.RFC3339Nano),
		ForkReadyMS:          forkReadyMS,
		BaselineRoleMS:       captures.Baseline.Elapsed.Milliseconds(),
		CandidateRoleMS:      captures.Candidate.Elapsed.Milliseconds(),
		RoleCriticalPathMS:   captures.Critical.Milliseconds(),
		CleanupMS:            cleanupMS,
		TotalMS:              time.Since(totalStarted).Milliseconds(),
		Baseline:             baselineEnvelope.Resource,
		Candidate:            candidateEnvelope.Resource,
		Decision:             "block",
		Finding:              "NEW_RUNTIME_ERROR",
	}
	t.Logf(
		"resource_economics.sample=%d fork_ms=%d role_critical_ms=%d cleanup_ms=%d total_ms=%d baseline_mem=%d candidate_mem=%d",
		sample,
		result.ForkReadyMS,
		result.RoleCriticalPathMS,
		result.CleanupMS,
		result.TotalMS,
		result.Baseline.GuestMemUsedProxyBytes,
		result.Candidate.GuestMemUsedProxyBytes,
	)
	return result
}

func captureBoxdRoleWithResourceTelemetry(
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	label string,
	sha string,
	runID string,
	scenarioID string,
	expectedStartedAt string,
) ([]byte, error) {
	result, err := execBoxdOK(ctx, client, machine, []string{
		"bash",
		"/tmp/rundiff_resource_role_capture.sh",
		sha,
		label,
		runID,
		scenarioID,
		expectedStartedAt,
	})
	if err != nil {
		return nil, fmt.Errorf("capture resource telemetry %s: %w", label, err)
	}
	body := []byte(strings.TrimSpace(result.Stdout))
	if !json.Valid(body) {
		return nil, fmt.Errorf(
			"capture resource telemetry %s returned invalid JSON: %s",
			label,
			result.Stdout,
		)
	}
	return body, nil
}

func collectGuestResourceSnapshot(
	t *testing.T,
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	stage string,
	role string,
	detailed bool,
) guestResourceSnapshot {
	t.Helper()

	detail := "0"
	if detailed {
		detail = "1"
	}
	result, err := execBoxdOK(ctx, client, machine, []string{
		"python3",
		"/tmp/rundiff_resource_snapshot.py",
		stage,
		role,
		detail,
	})
	if err != nil {
		t.Fatalf("collect resource snapshot %s/%s: %v", stage, role, err)
	}

	var snapshot guestResourceSnapshot
	if err := json.Unmarshal([]byte(strings.TrimSpace(result.Stdout)), &snapshot); err != nil {
		t.Fatalf("decode resource snapshot %s/%s: %v", stage, role, err)
	}
	snapshot.Machine = machine.Name
	validateGuestResourceSnapshot(t, snapshot)
	return snapshot
}

func decodeResourceRoleEnvelope(t *testing.T, body []byte) resourceRoleEnvelope {
	t.Helper()

	var envelope resourceRoleEnvelope
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode resource role envelope: %v", err)
	}
	if len(envelope.Capture) == 0 || !json.Valid(envelope.Capture) {
		t.Fatal("resource role envelope capture is missing or invalid")
	}
	validateGuestResourceSnapshot(t, envelope.Resource)
	return envelope
}

func validateGuestResourceSnapshot(t *testing.T, snapshot guestResourceSnapshot) {
	t.Helper()

	if snapshot.CollectedAtUTC == "" || snapshot.Stage == "" || snapshot.Role == "" {
		t.Fatalf("resource snapshot identity incomplete: %#v", snapshot)
	}
	if snapshot.GuestMemTotalBytes <= 0 ||
		snapshot.GuestMemAvailableBytes <= 0 ||
		snapshot.GuestMemUsedProxyBytes <= 0 ||
		snapshot.ProcessRSSSumBytes <= 0 ||
		snapshot.RootFSUsedBytes <= 0 {
		t.Fatalf("resource snapshot core metrics invalid: %#v", snapshot)
	}
}

func summarizeResourceEconomicsSamples(
	samples []resourceLifecycleSample,
) resourceEconomicsSummary {
	var memUsed []int64
	var rss []int64
	var rootFS []int64
	var postgresVolume []int64
	var postgresRW []int64
	var fork []int64
	var roleCritical []int64
	var cleanup []int64

	for _, sample := range samples {
		for _, snapshot := range []guestResourceSnapshot{
			sample.Baseline,
			sample.Candidate,
		} {
			memUsed = append(memUsed, snapshot.GuestMemUsedProxyBytes)
			rss = append(rss, snapshot.ProcessRSSSumBytes)
			rootFS = append(rootFS, snapshot.RootFSUsedBytes)
			if snapshot.PostgresVolumeBytes != nil {
				postgresVolume = append(postgresVolume, *snapshot.PostgresVolumeBytes)
			}
			if snapshot.PostgresSizeRWBytes != nil {
				postgresRW = append(postgresRW, *snapshot.PostgresSizeRWBytes)
			}
		}
		fork = append(fork, sample.ForkReadyMS)
		roleCritical = append(roleCritical, sample.RoleCriticalPathMS)
		cleanup = append(cleanup, sample.CleanupMS)
	}

	return resourceEconomicsSummary{
		ChildGuestMemUsedProxyBytes: summarizeInt64Metric(memUsed),
		ChildProcessRSSSumBytes:     summarizeInt64Metric(rss),
		ChildRootFSUsedBytes:        summarizeInt64Metric(rootFS),
		ChildPostgresVolumeBytes:    summarizeInt64Metric(postgresVolume),
		ChildPostgresSizeRWBytes:    summarizeInt64Metric(postgresRW),
		ForkReadyMS:                 summarizeInt64Metric(fork),
		RoleCriticalPathMS:          summarizeInt64Metric(roleCritical),
		CleanupMS:                   summarizeInt64Metric(cleanup),
	}
}

func summarizeInt64Metric(values []int64) resourceMetricSummary {
	if len(values) == 0 {
		return resourceMetricSummary{}
	}
	ordered := append([]int64(nil), values...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i] < ordered[j] })
	middle := len(ordered) / 2
	median := ordered[middle]
	if len(ordered)%2 == 0 {
		median = (ordered[middle-1] + ordered[middle]) / 2
	}
	return resourceMetricSummary{
		Count:  int64(len(ordered)),
		Median: median,
		Min:    ordered[0],
		Max:    ordered[len(ordered)-1],
	}
}

func writeResourceEconomicsReport(t *testing.T, report resourceEconomicsReport) {
	t.Helper()

	path := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_RESOURCE_ECONOMICS_REPORT"))
	if path == "" {
		path = filepath.Join("tmp", "rundiff", "boxd-resource-economics.json")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("create resource economics report directory: %v", err)
	}
	body, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatalf("marshal resource economics report: %v", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatalf("write resource economics report: %v", err)
	}
	t.Logf("resource_economics.report=%s", path)
}
