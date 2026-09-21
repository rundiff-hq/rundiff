package main

import (
	"bytes"
	"path/filepath"
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
