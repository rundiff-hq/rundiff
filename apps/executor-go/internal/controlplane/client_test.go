package controlplane

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

func TestClientUsesExactAttemptForClaimHeartbeatAndResult(t *testing.T) {
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer secret" {
			t.Fatalf("unexpected authorization header")
		}
		paths = append(paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")

		switch r.URL.Path {
		case "/api/executions/exec-1/attempts/3/claim":
			json.NewEncoder(w).Encode(map[string]any{
				"request":               requestFixture(),
				"lease_expires_at":      "2026-09-21T13:00:30.000Z",
				"repository_capability": "repo-token",
			})
		case "/api/executions/exec-1/attempts/3/heartbeat":
			json.NewEncoder(w).Encode(map[string]any{
				"status":           "live",
				"lease_expires_at": "2026-09-21T13:01:00.000Z",
			})
		case "/api/executions/exec-1/attempts/3/result":
			w.WriteHeader(http.StatusAccepted)
			json.NewEncoder(w).Encode(map[string]any{"status": "accepted"})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := &Client{BaseURL: server.URL, Token: "secret"}
	assignment := Assignment{ExecutionID: "exec-1", AttemptNumber: 3}

	claim, err := client.Claim(context.Background(), assignment)
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if claim.Request.ExecutionID != assignment.ExecutionID {
		t.Fatalf("claim request identity mismatch")
	}
	if claim.RepositoryCapability != "repo-token" {
		t.Fatalf("repository capability = %q", claim.RepositoryCapability)
	}

	heartbeat, err := client.Heartbeat(context.Background(), assignment)
	if err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	if heartbeat.Status != "live" {
		t.Fatalf("unexpected heartbeat status %q", heartbeat.Status)
	}

	result := protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "failed",
		Payload:       json.RawMessage("null"),
	}
	if _, err := client.SubmitResult(context.Background(), assignment, result); err != nil {
		t.Fatalf("SubmitResult: %v", err)
	}

	want := []string{
		"/api/executions/exec-1/attempts/3/claim",
		"/api/executions/exec-1/attempts/3/heartbeat",
		"/api/executions/exec-1/attempts/3/result",
	}
	if len(paths) != len(want) {
		t.Fatalf("paths=%v want=%v", paths, want)
	}
	for i := range want {
		if paths[i] != want[i] {
			t.Fatalf("paths=%v want=%v", paths, want)
		}
	}
}

func TestHeartbeatReturnsTerminalAttemptState(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"status":              "superseded",
			"cancellation_reason": "superseded_by_new_pull_request_revision",
		})
	}))
	defer server.Close()

	client := &Client{BaseURL: server.URL, Token: "secret"}
	heartbeat, err := client.Heartbeat(
		context.Background(),
		Assignment{ExecutionID: "exec-1", AttemptNumber: 3},
	)
	if err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	if heartbeat.Status != "superseded" {
		t.Fatalf("unexpected status %q", heartbeat.Status)
	}
	if heartbeat.CancellationReason == nil ||
		*heartbeat.CancellationReason != "superseded_by_new_pull_request_revision" {
		t.Fatalf("unexpected cancellation reason")
	}
}

func requestFixture() protocol.RequestV1 {
	return protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "exec-1",
		ScenarioID:    "scenario-1",
		BaselineSHA:   "aaa",
		CandidateSHA:  "bbb",
		AttemptNumber: 3,
		Context: protocol.ContextV1{
			Repository:        "demo/shop",
			PullRequestNumber: 42,
		},
	}
}
