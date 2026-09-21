package runner

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/workspace"
)

type memoryRecorder struct {
	entries []journal.Entry
}

func (r *memoryRecorder) Append(entry journal.Entry) error {
	r.entries = append(r.entries, entry)
	return nil
}

func TestProcessRunsReferenceAdapterWithPortablePaths(t *testing.T) {
	recorder := &memoryRecorder{}
	process := Process{
		Command: []string{os.Args[0], "-test.run=TestProcessHelper"},
		Env: []string{
			"RUNDIFF_GO_PROCESS_HELPER=1",
			"RUNDIFF_GO_PROCESS_HELPER_EXPECT_PREPARED=1",
		},
		Stdout: io.Discard,
		Stderr: io.Discard,
	}

	result, err := process.Run(
		context.Background(),
		testRequest(),
		workspace.Prepared{
			BaselineEnvironment: map[string]string{
				"BUNDLE_PATH": "/tmp/base-bundle",
			},
			CandidateEnvironment: map[string]string{
				"BUNDLE_PATH": "/tmp/candidate-bundle",
			},
		},
		recorder,
	)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q", result.Status)
	}

	var sawWorkspace bool
	var sawProcess bool
	for _, entry := range recorder.entries {
		if entry.ResourceKind == "workspace" && entry.Kind == "resource_created" {
			sawWorkspace = true
		}
		if entry.ResourceKind == "process" && entry.Kind == "resource_created" {
			sawProcess = true
		}
	}
	if !sawWorkspace || !sawProcess {
		t.Fatalf("expected workspace and process journal entries: %+v", recorder.entries)
	}
}

func TestProcessHelper(t *testing.T) {
	if os.Getenv("RUNDIFF_GO_PROCESS_HELPER") != "1" {
		return
	}

	requestPath := os.Getenv("RUNDIFF_EXECUTOR_REQUEST_PATH")
	resultPath := os.Getenv("RUNDIFF_EXECUTOR_RESULT_PATH")
	if requestPath == "" || resultPath == "" {
		os.Exit(91)
	}
	if _, err := protocol.LoadRequest(requestPath); err != nil {
		os.Exit(92)
	}
	if os.Getenv("RUNDIFF_GO_PROCESS_HELPER_EXPECT_PREPARED") == "1" {
		var baseline map[string]string
		if err := json.Unmarshal(
			[]byte(os.Getenv("RUNDIFF_PREPARED_BASELINE_RUNTIME_ENV_JSON")),
			&baseline,
		); err != nil || baseline["BUNDLE_PATH"] != "/tmp/base-bundle" {
			os.Exit(94)
		}
		var candidate map[string]string
		if err := json.Unmarshal(
			[]byte(os.Getenv("RUNDIFF_PREPARED_CANDIDATE_RUNTIME_ENV_JSON")),
			&candidate,
		); err != nil || candidate["BUNDLE_PATH"] != "/tmp/candidate-bundle" {
			os.Exit(95)
		}
	}

	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow","findings":[]}}`),
	}
	if err := protocol.WriteResult(resultPath, result); err != nil {
		os.Exit(93)
	}
	os.Exit(0)
}

func TestProcessConvertsMissingResultToFailedPortableResult(t *testing.T) {
	script := filepath.Join(t.TempDir(), "success-without-result")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	result, err := (Process{
		Command: []string{script},
		Stdout:  io.Discard,
		Stderr:  io.Discard,
	}).Run(
		context.Background(),
		testRequest(),
		workspace.Prepared{},
		&memoryRecorder{},
	)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != "failed" {
		t.Fatalf("expected failed, got %q", result.Status)
	}
	if result.ErrorClass == nil || *result.ErrorClass != "RunDiff::Executor::ReferenceResultError" {
		t.Fatalf("unexpected error class: %+v", result.ErrorClass)
	}
}

func testRequest() protocol.RequestV1 {
	return protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "exec-process",
		ScenarioID:    "scenario-process",
		BaselineSHA:   "aaa",
		CandidateSHA:  "bbb",
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository:        "demo/shop",
			PullRequestNumber: 42,
		},
	}
}
