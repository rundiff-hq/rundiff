package agent

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/controlplane"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/repositorycapability"
)

type fakeControlPlane struct {
	claim       controlplane.Claim
	heartbeats  []controlplane.Heartbeat
	submissions []protocol.ResultV1
}

func (f *fakeControlPlane) Claim(
	context.Context,
	controlplane.Assignment,
) (controlplane.Claim, error) {
	return f.claim, nil
}

func (f *fakeControlPlane) Heartbeat(
	context.Context,
	controlplane.Assignment,
) (controlplane.Heartbeat, error) {
	if len(f.heartbeats) == 0 {
		return controlplane.Heartbeat{}, errors.New("no heartbeat")
	}
	next := f.heartbeats[0]
	f.heartbeats = f.heartbeats[1:]
	return next, nil
}

func (f *fakeControlPlane) SubmitResult(
	_ context.Context,
	_ controlplane.Assignment,
	result protocol.ResultV1,
) (controlplane.Submission, error) {
	f.submissions = append(f.submissions, result)
	return controlplane.Submission{Status: "accepted"}, nil
}

type memoryJournal struct {
	entries []journal.Entry
}

func (j *memoryJournal) Append(entry journal.Entry) error {
	j.entries = append(j.entries, entry)
	return nil
}

type immediateEngine struct {
	result protocol.ResultV1
}

func (e immediateEngine) Execute(
	context.Context,
	protocol.RequestV1,
) (protocol.ResultV1, error) {
	return e.result, nil
}

type capabilityEngine struct {
	result protocol.ResultV1
	token  string
}

func (e *capabilityEngine) Execute(
	ctx context.Context,
	_ protocol.RequestV1,
) (protocol.ResultV1, error) {
	e.token = repositorycapability.Token(ctx)
	return e.result, nil
}

type blockingEngine struct {
	cancelled chan struct{}
}

func (e blockingEngine) Execute(
	ctx context.Context,
	_ protocol.RequestV1,
) (protocol.ResultV1, error) {
	<-ctx.Done()
	close(e.cancelled)
	return protocol.Failed("RunDiff::Executor::Cancelled", ctx.Err().Error()), nil
}

func TestAgentClaimsExactAttemptAndSubmitsResult(t *testing.T) {
	request := requestFixture()
	cp := &fakeControlPlane{
		claim: controlplane.Claim{
			Request:        request,
			LeaseExpiresAt: time.Now().Add(time.Minute),
		},
	}
	recorder := &memoryJournal{}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow"}}`),
	}
	agent := &Agent{
		ControlPlane: cp,
		Engine:       immediateEngine{result: result},
		Journal:      recorder,
	}

	outcome, err := agent.Run(
		context.Background(),
		controlplane.Assignment{ExecutionID: request.ExecutionID, AttemptNumber: 1},
	)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if outcome.Submission.Status != "accepted" {
		t.Fatalf("unexpected submission: %+v", outcome.Submission)
	}
	if len(cp.submissions) != 1 {
		t.Fatalf("expected one result submission, got %d", len(cp.submissions))
	}
}

func TestAgentCancelsWorkWhenHeartbeatReportsSuperseded(t *testing.T) {
	request := requestFixture()
	reason := "superseded_by_new_pull_request_revision"
	cp := &fakeControlPlane{
		claim: controlplane.Claim{
			Request:        request,
			LeaseExpiresAt: time.Now().Add(time.Minute),
		},
		heartbeats: []controlplane.Heartbeat{{
			Status:             "superseded",
			CancellationReason: &reason,
		}},
	}
	recorder := &memoryJournal{}
	cancelled := make(chan struct{})
	agent := &Agent{
		ControlPlane:      cp,
		Engine:            blockingEngine{cancelled: cancelled},
		Journal:           recorder,
		HeartbeatInterval: time.Millisecond,
	}

	_, err := agent.Run(
		context.Background(),
		controlplane.Assignment{ExecutionID: request.ExecutionID, AttemptNumber: 1},
	)
	if !errors.Is(err, ErrAttemptNoLongerLive) {
		t.Fatalf("expected ErrAttemptNoLongerLive, got %v", err)
	}
	select {
	case <-cancelled:
	default:
		t.Fatal("engine was not cancelled")
	}
	if len(cp.submissions) != 0 {
		t.Fatal("superseded attempt must not submit a late result")
	}
}

func requestFixture() protocol.RequestV1 {
	return protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "exec-agent",
		ScenarioID:    "scenario-agent",
		BaselineSHA:   "aaa",
		CandidateSHA:  "bbb",
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository:        "demo/shop",
			PullRequestNumber: 42,
		},
	}
}

func TestAgentScopesRepositoryCapabilityToExecutionContext(t *testing.T) {
	request := requestFixture()
	cp := &fakeControlPlane{
		claim: controlplane.Claim{
			Request:              request,
			LeaseExpiresAt:       time.Now().Add(time.Minute),
			RepositoryCapability: "repo-token",
		},
	}
	recorder := &memoryJournal{}
	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       json.RawMessage(`{"result":{"merge_recommendation":"allow"}}`),
	}
	engine := &capabilityEngine{result: result}
	managed := &Agent{
		ControlPlane: cp,
		Engine:       engine,
		Journal:      recorder,
	}

	if _, err := managed.Run(
		context.Background(),
		controlplane.Assignment{ExecutionID: request.ExecutionID, AttemptNumber: 1},
	); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if engine.token != "repo-token" {
		t.Fatalf("repository capability = %q, want repo-token", engine.token)
	}
	for _, entry := range recorder.entries {
		if entry.Message == "repo-token" || entry.Resource == "repo-token" {
			t.Fatal("repository capability must not be written to the resource journal")
		}
	}
}
