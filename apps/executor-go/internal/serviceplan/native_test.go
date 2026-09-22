package serviceplan

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestNativeCompilerCompilesProcessAndComposeServices(t *testing.T) {
	root := t.TempDir()
	writeConfig(t, root, `version: 1
scenario:
  path: /demo
subject:
  persistence: postgresql
  setup:
    mode: auto
  services:
    - name: mock-api
      type: process
      runtime: ruby
      entrypoint: script/mock_api.rb
      args: ["--quiet"]
      url_env: MOCK_API_URL
      readiness:
        type: http
        path: /health
    - name: cache
      type: compose
      manifest: compose.yml
      service: redis
      target_port: 6379
      url_scheme: redis
      url_env: REDIS_URL
      readiness:
        type: tcp
        timeout_seconds: 10
`)

	plan, err := NewNativeCompiler().Compile(context.Background(), root)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if plan.SchemaVersion != SchemaVersion {
		t.Fatalf("schema version = %q", plan.SchemaVersion)
	}
	if len(plan.Steps) != 6 {
		t.Fatalf("steps = %d, want 6: %+v", len(plan.Steps), plan.Steps)
	}
	wantOperations := []string{
		"process.start",
		"http.wait_ready",
		"process.stop",
		"compose.run",
		"tcp.wait_ready",
		"compose.stop",
	}
	gotOperations := make([]string, 0, len(plan.Steps))
	for _, step := range plan.Steps {
		gotOperations = append(gotOperations, step.Operation)
	}
	if !reflect.DeepEqual(gotOperations, wantOperations) {
		t.Fatalf("operations = %#v, want %#v", gotOperations, wantOperations)
	}
	if got := plan.Steps[0].Details["port_env"]; got != "PORT" {
		t.Fatalf("default port_env = %#v", got)
	}
	if got := plan.Steps[1].Details["timeout_seconds"]; got != float64(5) {
		t.Fatalf("default timeout = %#v", got)
	}
}

func TestNativeCompilerReturnsEmptyPlanWithoutConfiguration(t *testing.T) {
	plan, err := NewNativeCompiler().Compile(
		context.Background(),
		t.TempDir(),
	)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if len(plan.Steps) != 0 {
		t.Fatalf("steps = %+v, want empty", plan.Steps)
	}
}

func TestNativeCompilerRejectsUnknownKeys(t *testing.T) {
	root := t.TempDir()
	writeConfig(t, root, `version: 1
subject:
  mystery: true
`)
	if _, err := NewNativeCompiler().Compile(
		context.Background(),
		root,
	); err == nil {
		t.Fatal("expected unknown-key error")
	}
}

func TestNativeCompilerRejectsDuplicateServiceURLVars(t *testing.T) {
	root := t.TempDir()
	writeConfig(t, root, `version: 1
subject:
  services:
    - name: one
      type: process
      runtime: ruby
      entrypoint: one.rb
      url_env: SERVICE_URL
      readiness:
        type: tcp
    - name: two
      type: process
      runtime: node
      entrypoint: two.js
      url_env: SERVICE_URL
      readiness:
        type: tcp
`)
	if _, err := NewNativeCompiler().Compile(
		context.Background(),
		root,
	); err == nil {
		t.Fatal("expected duplicate url_env error")
	}
}

func TestNativeCompilerRejectsMixedServiceKeys(t *testing.T) {
	root := t.TempDir()
	writeConfig(t, root, `version: 1
subject:
  services:
    - name: bad
      type: process
      runtime: ruby
      entrypoint: bad.rb
      manifest: compose.yml
      url_env: BAD_URL
      readiness:
        type: tcp
`)
	if _, err := NewNativeCompiler().Compile(
		context.Background(),
		root,
	); err == nil {
		t.Fatal("expected mixed-key error")
	}
}

func writeConfig(t *testing.T, root string, body string) {
	t.Helper()
	if err := os.WriteFile(
		filepath.Join(root, "rundiff.yml"),
		[]byte(body),
		0o600,
	); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
}

func TestNodeScenarioURLEnvRequiresOneNodeService(t *testing.T) {
	root := t.TempDir()
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
	value, err := NodeScenarioURLEnv(root)
	if err != nil {
		t.Fatal(err)
	}
	if value != "NODE_APP_URL" {
		t.Fatalf("url env = %q", value)
	}
}
