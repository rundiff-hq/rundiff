package sensor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRegistryResolvesPortableRails(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "environment.rb"), []byte("# rails"), 0o600); err != nil {
		t.Fatal(err)
	}
	spec, err := NewRegistry("/tool").Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if spec.Adapter != "rails" || spec.Mode != "tool_owned_portable_rails" || spec.Runtime != "ruby" {
		t.Fatalf("unexpected spec: %#v", spec)
	}
}

func TestRegistryResolvesSubjectOwnedRails(t *testing.T) {
	root := t.TempDir()
	files := append([]string{"config/environment.rb"}, railsSubjectOwnedMarkers...)
	for _, relative := range files {
		path := filepath.Join(root, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("# marker"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	spec, err := NewRegistry("/tool").Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if spec.Adapter != "rails" || spec.Mode != "subject_owned_rails" || spec.Runtime != "ruby" {
		t.Fatalf("unexpected spec: %#v", spec)
	}
}

func TestRegistryRejectsUnsupportedSubject(t *testing.T) {
	if _, err := NewRegistry("/tool").Resolve(t.TempDir()); err == nil {
		t.Fatal("expected unsupported runtime sensor error")
	}
}

func TestRegistryResolvesNodeHTTPSensor(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "package.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	config := `version: 1
scenario:
  path: /scenario
subject:
  services:
    - name: app
      type: process
      runtime: node
      entrypoint: server.mjs
      url_env: NODE_APP_URL
      readiness:
        type: http
        path: /health
`
	if err := os.WriteFile(filepath.Join(root, "rundiff.yml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	spec, err := NewRegistry("/tool").Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if spec.Adapter != "node" || spec.Runtime != "node" ||
		spec.Mode != "tool_owned_node_http" || spec.TargetURLEnv != "NODE_APP_URL" {
		t.Fatalf("unexpected Node spec: %#v", spec)
	}
}

func TestValidateCaptureFencesSensorAndExecutionIdentity(t *testing.T) {
	spec := Spec{Adapter: "rails", Mode: "tool_owned_portable_rails", Runtime: "ruby"}
	capture := map[string]any{
		"sensor": map[string]any{
			"schema_version": "1",
			"adapter":        "rails",
			"mode":           "tool_owned_portable_rails",
			"runtime":        "ruby",
		},
		"id":                   "candidate",
		"execution_id":         "sensor-execution",
		"run_id":               "execution-1",
		"scenario_id":          "scenario-1",
		"subject":              "github-pull-request",
		"ref":                  "candidate",
		"sha":                  "abc123",
		"status":               "passed",
		"measurements":         map[string]any{},
		"attributions":         map[string]any{},
		"durable_observations": []any{},
	}
	body, _ := json.Marshal(capture)
	expected := ExpectedCapture{
		RunID: "execution-1", ScenarioID: "scenario-1",
		Subject: "github-pull-request", Label: "candidate",
		SHA: "abc123", Spec: spec,
	}
	if err := ValidateCapture(body, expected); err != nil {
		t.Fatalf("ValidateCapture: %v", err)
	}

	capture["sha"] = "wrong"
	body, _ = json.Marshal(capture)
	if err := ValidateCapture(body, expected); err == nil {
		t.Fatal("expected SHA mismatch")
	}
}
