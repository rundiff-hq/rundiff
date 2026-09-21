package executor

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/metrics"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/workspace"
)

type memoryJournal struct {
	entries []journal.Entry
}

func (j *memoryJournal) Append(entry journal.Entry) error {
	j.entries = append(j.entries, entry)
	return nil
}

type memoryMetrics struct {
	events []metrics.Event
}

func (m *memoryMetrics) Record(event metrics.Event) error {
	m.events = append(m.events, event)
	return nil
}

type staticRunner struct {
	result protocol.ResultV1
	err    error
}

func (r staticRunner) Run(
	context.Context,
	protocol.RequestV1,
	workspace.Prepared,
	journal.Recorder,
) (protocol.ResultV1, error) {
	return r.result, r.err
}

type fakeWorkspace struct{}

type fakeBootstrapper struct{}

func (fakeBootstrapper) Bootstrap(
	_ context.Context,
	role string,
	root string,
) (map[string]string, error) {
	return map[string]string{
		"BUNDLE_GEMFILE": root + "/Gemfile",
		"RUNDIFF_ROLE":   role,
	}, nil
}

type recordingRunner struct {
	result   protocol.ResultV1
	prepared workspace.Prepared
}

func (r *recordingRunner) Run(
	_ context.Context,
	_ protocol.RequestV1,
	prepared workspace.Prepared,
	_ journal.Recorder,
) (protocol.ResultV1, error) {
	r.prepared = prepared
	return r.result, nil
}

func (fakeWorkspace) Prepare(
	context.Context,
	protocol.RequestV1,
	journal.Recorder,
) (workspace.Prepared, error) {
	return workspace.Prepared{Root: "/tmp/workspace"}, nil
}

func (fakeWorkspace) Clone(
	_ context.Context,
	_ protocol.RequestV1,
	prepared workspace.Prepared,
	_ journal.Recorder,
) (workspace.Prepared, error) {
	prepared.BaselineRoot = "/tmp/workspace/base"
	prepared.CandidateRoot = "/tmp/workspace/candidate"
	return prepared, nil
}

func (fakeWorkspace) Teardown(
	context.Context,
	protocol.RequestV1,
	workspace.Prepared,
	journal.Recorder,
) error {
	return nil
}

func TestExecutorRecordsNativePrepareCloneMetrics(t *testing.T) {
	recorder := &memoryJournal{}
	phaseMetrics := &memoryMetrics{}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow","findings":[]}}`),
	}
	executor := NewManaged(
		recorder,
		phaseMetrics,
		staticRunner{result: result},
		fakeWorkspace{},
	)

	actual, err := executor.Execute(context.Background(), requestFixture())
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if actual.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q", actual.Status)
	}

	var sawPrepare bool
	var sawClone bool
	for _, event := range phaseMetrics.events {
		if event.Phase == "prepare" && event.Implementation == "go" {
			sawPrepare = true
		}
		if event.Phase == "clone" && event.Implementation == "go" {
			sawClone = true
		}
	}
	if !sawPrepare || !sawClone {
		t.Fatalf("missing native workspace metrics: %+v", phaseMetrics.events)
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

func TestExecutorBootstrapsBothPreparedSubjectsInGo(t *testing.T) {
	recorder := &memoryJournal{}
	phaseMetrics := &memoryMetrics{}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow","findings":[]}}`),
	}
	run := &recordingRunner{result: result}
	engine := NewManaged(
		recorder,
		phaseMetrics,
		run,
		fakeWorkspace{},
	).WithBootstrapper(fakeBootstrapper{})

	actual, err := engine.Execute(context.Background(), requestFixture())
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if actual.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q", actual.Status)
	}
	if run.prepared.BaselineEnvironment["RUNDIFF_ROLE"] != "base" {
		t.Fatalf("missing base bootstrap environment: %+v", run.prepared)
	}
	if run.prepared.CandidateEnvironment["RUNDIFF_ROLE"] != "candidate" {
		t.Fatalf("missing candidate bootstrap environment: %+v", run.prepared)
	}

	var baseBootstrap bool
	var candidateBootstrap bool
	for _, event := range phaseMetrics.events {
		if event.Phase == "bootstrap" &&
			event.Implementation == "go" &&
			event.Role == "base" {
			baseBootstrap = true
		}
		if event.Phase == "bootstrap" &&
			event.Implementation == "go" &&
			event.Role == "candidate" {
			candidateBootstrap = true
		}
	}
	if !baseBootstrap || !candidateBootstrap {
		t.Fatalf("missing Go bootstrap metrics: %+v", phaseMetrics.events)
	}
}
