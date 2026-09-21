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

type fakeSubjectPreparer struct{}

func (fakeSubjectPreparer) Prepare(
	_ context.Context,
	_ protocol.RequestV1,
	role string,
	_ string,
	runtimeEnv map[string]string,
) (map[string]string, error) {
	env := map[string]string{}
	for key, value := range runtimeEnv {
		env[key] = value
	}
	env["DATABASE_URL"] = "postgres://example/" + role
	env["RUNDIFF_SUBJECT_ROLE"] = role
	return env, nil
}

type fakeServiceController struct {
	started []string
	readied []string
	stopped []string
}

func (s *fakeServiceController) Start(
	_ context.Context,
	_ protocol.RequestV1,
	role string,
	_ string,
	_ map[string]string,
	_ journal.Recorder,
) (any, map[string]string, error) {
	s.started = append(s.started, role)
	return role + "-session", map[string]string{
		"MOCK_API_URL": "http://127.0.0.1/" + role,
	}, nil
}

func (s *fakeServiceController) Ready(
	_ context.Context,
	_ protocol.RequestV1,
	role string,
	_ string,
	env map[string]string,
	_ any,
) error {
	if env["MOCK_API_URL"] == "" {
		return context.Canceled
	}
	s.readied = append(s.readied, role)
	return nil
}

func (s *fakeServiceController) Stop(
	_ context.Context,
	_ protocol.RequestV1,
	role string,
	_ string,
	_ map[string]string,
	_ any,
	_ journal.Recorder,
) error {
	s.stopped = append(s.stopped, role)
	return nil
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

func TestExecutorPreparesSubjectStateForBothRolesInGo(t *testing.T) {
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
	).
		WithBootstrapper(fakeBootstrapper{}).
		WithSubjectPreparer(fakeSubjectPreparer{})

	actual, err := engine.Execute(context.Background(), requestFixture())
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if actual.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q", actual.Status)
	}
	if run.prepared.BaselineSubjectEnvironment["RUNDIFF_SUBJECT_ROLE"] != "base" {
		t.Fatalf("missing base subject environment: %+v", run.prepared)
	}
	if run.prepared.CandidateSubjectEnvironment["RUNDIFF_SUBJECT_ROLE"] != "candidate" {
		t.Fatalf("missing candidate subject environment: %+v", run.prepared)
	}
	if run.prepared.BaselineSubjectEnvironment["BUNDLE_GEMFILE"] == "" {
		t.Fatalf("bootstrap env did not survive subject prepare: %+v", run.prepared)
	}

	var basePrepare bool
	var candidatePrepare bool
	for _, event := range phaseMetrics.events {
		if event.Phase == "subject_prepare" &&
			event.Implementation == "go" &&
			event.Role == "base" {
			basePrepare = true
		}
		if event.Phase == "subject_prepare" &&
			event.Implementation == "go" &&
			event.Role == "candidate" {
			candidatePrepare = true
		}
	}
	if !basePrepare || !candidatePrepare {
		t.Fatalf("missing subject_prepare metrics: %+v", phaseMetrics.events)
	}
}


func TestExecutorOwnsServiceStartReadyAndStopInGo(t *testing.T) {
	recorder := &memoryJournal{}
	phaseMetrics := &memoryMetrics{}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow","findings":[]}}`),
	}
	run := &recordingRunner{result: result}
	serviceController := &fakeServiceController{}
	engine := NewManaged(
		recorder,
		phaseMetrics,
		run,
		fakeWorkspace{},
	).
		WithBootstrapper(fakeBootstrapper{}).
		WithSubjectPreparer(fakeSubjectPreparer{}).
		WithServiceController(serviceController)

	actual, err := engine.Execute(context.Background(), requestFixture())
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if actual.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q", actual.Status)
	}
	if !run.prepared.ServicesPrepared {
		t.Fatalf("reference process did not receive services-prepared ownership")
	}
	if run.prepared.BaselineSubjectEnvironment["MOCK_API_URL"] !=
		"http://127.0.0.1/base" {
		t.Fatalf("base service env missing: %+v", run.prepared)
	}
	if run.prepared.CandidateSubjectEnvironment["MOCK_API_URL"] !=
		"http://127.0.0.1/candidate" {
		t.Fatalf("candidate service env missing: %+v", run.prepared)
	}
	if len(serviceController.started) != 2 ||
		len(serviceController.readied) != 2 ||
		len(serviceController.stopped) != 2 {
		t.Fatalf("unexpected service lifecycle: %+v", serviceController)
	}

	phases := map[string]int{}
	for _, event := range phaseMetrics.events {
		phases[event.Phase]++
	}
	if phases["start"] != 2 ||
		phases["ready"] != 2 ||
		phases["stop"] != 2 {
		t.Fatalf("missing service phase metrics: %+v", phaseMetrics.events)
	}
}
