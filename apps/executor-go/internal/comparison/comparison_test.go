package comparison

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

func TestPairMatchesRubyOracle(t *testing.T) {
	toolRoot, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name      string
		baseline  map[string]any
		candidate map[string]any
		changed   []string
	}{
		{
			name: "durable regression with attribution",
			baseline: execution("run-1", "scenario-1", 100, 14, []any{
				runtimeObservation("worker_wall_ms", 30),
			}),
			candidate: func() map[string]any {
				value := execution("run-1", "scenario-1", 145, 19, []any{
					runtimeObservation("worker_wall_ms", 80),
					map[string]any{
						"signal":     "sql_queries",
						"path":       "app/controllers/demo_controller.rb",
						"start_line": 20,
						"end_line":   20,
						"confidence": "runtime",
					},
				})
				return value
			}(),
			changed: []string{"app/controllers/demo_controller.rb"},
		},
		{
			name:      "optional signals and split queue stages",
			baseline:  asyncExecution("run-2", "scenario-2", 100, 10, 20, 50),
			candidate: asyncExecution("run-2", "scenario-2", 105, 12, 55, 90),
			changed:   []string{},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			native, err := Pair(tc.baseline, tc.candidate, tc.changed)
			if err != nil {
				t.Fatalf("native Pair: %v", err)
			}
			ruby := rubyOracle(t, toolRoot, tc.baseline, tc.candidate, tc.changed)
			if !reflect.DeepEqual(normalize(native), normalize(ruby)) {
				nativeBody, _ := json.MarshalIndent(native, "", "  ")
				rubyBody, _ := json.MarshalIndent(ruby, "", "  ")
				t.Fatalf("Go/Ruby mismatch\nGo:\n%s\nRuby:\n%s", nativeBody, rubyBody)
			}
		})
	}
}

func TestPairRejectsIdentityMismatch(t *testing.T) {
	base := execution("run-1", "scenario-1", 100, 1, nil)
	candidate := execution("run-1", "scenario-2", 100, 1, nil)
	if _, err := Pair(base, candidate, nil); err == nil {
		t.Fatal("expected identity mismatch")
	}
}

func execution(
	runID string,
	scenarioID string,
	duration float64,
	queries float64,
	observations []any,
) map[string]any {
	return map[string]any{
		"id":          "subject",
		"run_id":      runID,
		"scenario_id": scenarioID,
		"measurements": map[string]any{
			"duration_ms":     duration,
			"thread_cpu_ms":   20.0,
			"sql_queries":     queries,
			"background_jobs": 1.0,
			"emails":          0.0,
			"http_requests":   1.0,
			"errors":          0.0,
		},
		"durable_observations": observations,
	}
}

func asyncExecution(
	runID string,
	scenarioID string,
	duration float64,
	scheduled float64,
	dispatch float64,
	worker float64,
) map[string]any {
	value := execution(runID, scenarioID, duration, 4, nil)
	m := value["measurements"].(map[string]any)
	m["queue_wait_ms"] = scheduled + dispatch
	m["scheduled_delay_ms"] = scheduled
	m["dispatch_wait_ms"] = dispatch
	m["worker_wall_ms"] = worker
	m["worker_thread_cpu_ms"] = worker / 4
	return value
}

func runtimeObservation(signal string, value float64) map[string]any {
	return map[string]any{
		"signal":  signal,
		"payload": map[string]any{"value": value},
	}
}

func rubyOracle(
	t *testing.T,
	toolRoot string,
	baseline map[string]any,
	candidate map[string]any,
	changed []string,
) map[string]any {
	t.Helper()
	dir := t.TempDir()
	basePath := writeJSON(t, dir, "base.json", baseline)
	candidatePath := writeJSON(t, dir, "candidate.json", candidate)
	changedPath := writeJSON(t, dir, "changed.json", changed)
	outputPath := filepath.Join(dir, "pair.json")
	command := exec.Command(
		"ruby",
		filepath.Join(toolRoot, "script", "rundiff_compare_captures.rb"),
		basePath,
		candidatePath,
		changedPath,
		outputPath,
	)
	command.Dir = toolRoot
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("Ruby oracle: %v: %s", err, output)
	}
	body, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func writeJSON(t *testing.T, dir, name string, value any) string {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func normalize(value any) any {
	body, _ := json.Marshal(value)
	var result any
	_ = json.Unmarshal(body, &result)
	return result
}
