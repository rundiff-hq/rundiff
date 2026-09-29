package boxd

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

func TestLiveParallelForkIsolation(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd parallel fork proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd parallel fork proof")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live Boxd parallel fork proof")
	}

	client, err := NewSessionPairSDK(
		"node",
		"sdkbridge/session.mjs",
		"sdkbridge/bridge.mjs",
	)
	if err != nil {
		t.Fatalf("start pair SDK sessions: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close pair SDK sessions: %v", closeErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	parentName := "rundiff-pp-" + proofID
	baselineName := "rundiff-pb-" + proofID
	candidateName := "rundiff-pc-" + proofID

	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create parallel-fork parent: %v", err)
	}
	defer removeMachine(t, client, parent)

	if _, err := execEventually(
		ctx,
		client,
		parent,
		[]string{"sh", "-c", "printf golden > /tmp/rundiff-parallel-state"},
	); err != nil {
		t.Fatalf("seed parallel-fork parent: %v", err)
	}

	forkStarted := time.Now()
	pair, err := compute.ForkPair(
		ctx,
		client,
		parent.Name,
		baselineName,
		candidateName,
	)
	if err != nil {
		t.Fatalf("parallel fork pair: %v", err)
	}
	t.Logf(
		"provider.parallel_fork_pair_ready_ms=%d",
		time.Since(forkStarted).Milliseconds(),
	)
	defer cleanupPair(t, client, pair)

	if _, err := execEventually(
		ctx,
		client,
		pair.Baseline,
		[]string{"sh", "-c", "printf baseline > /tmp/rundiff-parallel-state"},
	); err != nil {
		t.Fatalf("mutate parallel baseline: %v", err)
	}

	candidateState, err := execEventually(
		ctx,
		client,
		pair.Candidate,
		[]string{"cat", "/tmp/rundiff-parallel-state"},
	)
	if err != nil {
		t.Fatalf("read parallel candidate state: %v", err)
	}
	if got := strings.TrimSpace(candidateState.Stdout); got != "golden" {
		t.Fatalf("candidate state = %q, want golden", got)
	}

	parentState, err := execEventually(
		ctx,
		client,
		parent,
		[]string{"cat", "/tmp/rundiff-parallel-state"},
	)
	if err != nil {
		t.Fatalf("read parallel parent state: %v", err)
	}
	if got := strings.TrimSpace(parentState.Stdout); got != "golden" {
		t.Fatalf("parent state = %q, want golden", got)
	}

	t.Log("provider.parallel_fork_isolation=ok")
}
