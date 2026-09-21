package executor

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

type memoryJournal struct {
	entries []journal.Entry
}

func (j *memoryJournal) Append(entry journal.Entry) error {
	j.entries = append(j.entries, entry)
	return nil
}

type staticRunner struct {
	result protocol.ResultV1
	err    error
}

func (r staticRunner) Run(context.Context, protocol.RequestV1, journal.Recorder) (protocol.ResultV1, error) {
	return r.result, r.err
}

func TestExecutorRecordsLifecycleAroundPortableResult(t *testing.T) {
	recorder := &memoryJournal{}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow","findings":[]}}`),
	}
	executor := New(recorder, staticRunner{result: result})

	actual, err := executor.Execute(context.Background(), requestFixture())
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if actual.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q", actual.Status)
	}

	expected := []struct {
		kind  string
		phase Phase
	}{
		{"phase_started", PhasePrepare},
		{"phase_completed", PhasePrepare},
		{"phase_started", PhaseScenario},
		{"phase_completed", PhaseScenario},
		{"phase_started", PhaseCollect},
		{"phase_completed", PhaseCollect},
		{"phase_started", PhaseTeardown},
		{"phase_completed", PhaseTeardown},
	}
	if len(recorder.entries) != len(expected) {
		t.Fatalf("expected %d journal entries, got %d", len(expected), len(recorder.entries))
	}
	for index, want := range expected {
		got := recorder.entries[index]
		if got.Kind != want.kind || got.Phase != string(want.phase) {
			t.Fatalf("entry %d = %+v, want kind=%s phase=%s", index, got, want.kind, want.phase)
		}
	}
}

func TestExecutorConvertsRunnerErrorToFailedResult(t *testing.T) {
	recorder := &memoryJournal{}
	executor := New(recorder, staticRunner{err: context.Canceled})

	result, err := executor.Execute(context.Background(), requestFixture())
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if result.Status != "failed" {
		t.Fatalf("expected failed, got %q", result.Status)
	}
	if result.ErrorClass == nil || *result.ErrorClass != "RunDiff::Executor::GoSupervisorError" {
		t.Fatalf("unexpected error class: %+v", result.ErrorClass)
	}
}

func requestFixture() protocol.RequestV1 {
	return protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "exec-1",
		ScenarioID:    "scenario-1",
		BaselineSHA:   "aaa",
		CandidateSHA:  "bbb",
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository:        "demo/shop",
			PullRequestNumber: 42,
		},
	}
}
