package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateGoldenFixtures(t *testing.T) {
	request := filepath.Join("..", "..", "..", "..", "protocol", "executor", "v1", "fixtures", "request.json")
	result := filepath.Join("..", "..", "..", "..", "protocol", "executor", "v1", "fixtures", "result-allow.json")

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"validate", "--request", request, "--result", result}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate exit=%d stderr=%s", code, stderr.String())
	}
	if stdout.String() != "ok\n" {
		t.Fatalf("unexpected stdout: %q", stdout.String())
	}
}

func TestRunLocalRequiresRequestAndResult(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"run-local"}, &stdout, &stderr)
	if code != 2 {
		t.Fatalf("run-local exit=%d stderr=%s", code, stderr.String())
	}
	if stderr.String() != "run-local requires --request and --result\n" {
		t.Fatalf("unexpected stderr: %q", stderr.String())
	}
}

func TestSupervisorBenchmarkIdleReportsReady(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run(
		[]string{"supervisor-benchmark-idle", "--hold", "0s"},
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("supervisor-benchmark-idle exit=%d stderr=%s", code, stderr.String())
	}
	if stdout.String() != "RUNDIFF_SUPERVISOR_READY\n" {
		t.Fatalf("unexpected stdout: %q", stdout.String())
	}
}


func TestAgentUnclaimableCanExitSuccessfully(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":"execution attempt is not claimable"}`))
	}))
	defer server.Close()

	t.Setenv("RUNDIFF_EXECUTOR_TOKEN", "secret")
	tmp := t.TempDir()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run(
		[]string{
			"agent",
			"--control-plane-url", server.URL,
			"--execution-id", "exec-duplicate",
			"--attempt", "1",
			"--unclaimable-ok",
			"--cwd", tmp,
			"--journal", filepath.Join(tmp, "journal.jsonl"),
			"--metrics", filepath.Join(tmp, "metrics.jsonl"),
		},
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("agent exit=%d stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "assignment_status=already_claimed_or_complete") {
		t.Fatalf("unexpected stdout: %q", stdout.String())
	}
}
