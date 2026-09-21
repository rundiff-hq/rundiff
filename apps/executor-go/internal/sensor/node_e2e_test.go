package sensor

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestToolOwnedNodeHTTPSensorEmitsProtocolV1(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/scenario" {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	toolRoot, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "capture.json")
	env := append(os.Environ(),
		"RUNDIFF_SCENARIO_BASE_URL="+server.URL,
		"RUNDIFF_SCENARIO_PATH=/scenario",
		"RUNDIFF_RUN_ID=run-node",
		"RUNDIFF_SCENARIO_ID=node.http",
		"RUNDIFF_SUBJECT=github-pull-request",
		"RUNDIFF_EXECUTION_LABEL=candidate",
		"RUNDIFF_EXECUTION_SHA=abc123",
		"RUNDIFF_OUTPUT="+output,
		"RUNDIFF_SENSOR_SCHEMA_VERSION=1",
		"RUNDIFF_SENSOR_ADAPTER=node",
		"RUNDIFF_CAPTURE_RUNTIME=tool_owned_node_http",
		"RUNDIFF_SENSOR_RUNTIME=node",
	)
	command := exec.Command("node", filepath.Join(toolRoot, "script", "rundiff_capture_node.mjs"))
	command.Env = env
	if body, err := command.CombinedOutput(); err != nil {
		t.Fatalf("node sensor: %v\n%s", err, body)
	}
	body, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	spec := Spec{Adapter: "node", Mode: "tool_owned_node_http", Runtime: "node"}
	if err := ValidateCapture(body, ExpectedCapture{
		RunID: "run-node", ScenarioID: "node.http", Subject: "github-pull-request",
		Label: "candidate", SHA: "abc123", Spec: spec,
	}); err != nil {
		t.Fatalf("ValidateCapture: %v", err)
	}
	var capture map[string]any
	if err := json.Unmarshal(body, &capture); err != nil {
		t.Fatal(err)
	}
	if capture["status"] != "passed" || capture["http_status"] != float64(204) {
		t.Fatalf("unexpected capture: %#v", capture)
	}
	measurements := capture["measurements"].(map[string]any)
	if _, exists := measurements["sql_queries"]; exists {
		t.Fatal("Node black-box sensor must not fabricate SQL visibility")
	}
}

func TestToolOwnedNodeHTTPSensorReportsHTTPFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer server.Close()

	toolRoot, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "capture.json")
	command := exec.Command("node", filepath.Join(toolRoot, "script", "rundiff_capture_node.mjs"))
	command.Env = append(os.Environ(),
		"RUNDIFF_SCENARIO_BASE_URL="+server.URL,
		"RUNDIFF_SCENARIO_PATH=/scenario",
		"RUNDIFF_RUN_ID=run-node-failure",
		"RUNDIFF_SCENARIO_ID=node.http",
		"RUNDIFF_SUBJECT=github-pull-request",
		"RUNDIFF_EXECUTION_LABEL=candidate",
		"RUNDIFF_EXECUTION_SHA=def456",
		"RUNDIFF_OUTPUT="+output,
		"RUNDIFF_SENSOR_SCHEMA_VERSION=1",
		"RUNDIFF_SENSOR_ADAPTER=node",
		"RUNDIFF_CAPTURE_RUNTIME=tool_owned_node_http",
		"RUNDIFF_SENSOR_RUNTIME=node",
	)
	if body, err := command.CombinedOutput(); err != nil {
		t.Fatalf("node sensor process should capture HTTP failure without crashing: %v\n%s", err, body)
	}
	body, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var capture map[string]any
	if err := json.Unmarshal(body, &capture); err != nil {
		t.Fatal(err)
	}
	if capture["status"] != "failed" || capture["http_status"] != float64(500) {
		t.Fatalf("unexpected failure capture: %#v", capture)
	}
	measurements := capture["measurements"].(map[string]any)
	if measurements["errors"] != float64(1) {
		t.Fatalf("errors = %v, want 1", measurements["errors"])
	}
}
