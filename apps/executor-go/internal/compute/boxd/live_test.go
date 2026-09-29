package boxd

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

func TestLiveForkIsolation(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd provider proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd provider proof")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live Boxd provider proof")
	}

	client := NewSDK("node", "sdkbridge/bridge.mjs")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	parentName := "rundiff-p-" + proofID
	baselineName := "rundiff-b-" + proofID
	candidateName := "rundiff-c-" + proofID

	createStarted := time.Now()
	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create isolated parent: %v", err)
	}
	t.Logf("provider.create.parent_ready_ms=%d", time.Since(createStarted).Milliseconds())
	defer removeMachine(t, client, parent)

	if _, err := execEventually(
		ctx,
		client,
		parent,
		[]string{"sh", "-c", "printf golden > /tmp/rundiff-proof-state"},
	); err != nil {
		t.Fatalf("seed parent state: %v", err)
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
		t.Fatalf("fork pair: %v", err)
	}
	t.Logf("provider.fork_pair_ready_ms=%d", time.Since(forkStarted).Milliseconds())
	defer cleanupPair(t, client, pair)

	if _, err := execEventually(
		ctx,
		client,
		pair.Baseline,
		[]string{"sh", "-c", "printf baseline > /tmp/rundiff-proof-state"},
	); err != nil {
		t.Fatalf("mutate baseline state: %v", err)
	}

	candidateState, err := execEventually(
		ctx,
		client,
		pair.Candidate,
		[]string{"cat", "/tmp/rundiff-proof-state"},
	)
	if err != nil {
		t.Fatalf("read candidate inherited state: %v", err)
	}
	if got := strings.TrimSpace(candidateState.Stdout); got != "golden" {
		t.Fatalf("candidate state = %q, want golden", got)
	}

	parentState, err := execEventually(
		ctx,
		client,
		parent,
		[]string{"cat", "/tmp/rundiff-proof-state"},
	)
	if err != nil {
		t.Fatalf("read parent state after baseline mutation: %v", err)
	}
	if got := strings.TrimSpace(parentState.Stdout); got != "golden" {
		t.Fatalf("parent state = %q, want golden", got)
	}

	if _, err := execEventually(
		ctx,
		client,
		pair.Candidate,
		[]string{"sh", "-c", "printf candidate > /tmp/rundiff-proof-state"},
	); err != nil {
		t.Fatalf("mutate candidate state: %v", err)
	}

	baselineState, err := execEventually(
		ctx,
		client,
		pair.Baseline,
		[]string{"cat", "/tmp/rundiff-proof-state"},
	)
	if err != nil {
		t.Fatalf("read baseline isolated state: %v", err)
	}
	if got := strings.TrimSpace(baselineState.Stdout); got != "baseline" {
		t.Fatalf("baseline state = %q, want baseline", got)
	}

	t.Log("provider.live_fork_isolation=ok")
}

func execEventually(
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	argv []string,
) (compute.ExecResult, error) {
	var lastErr error
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	timeout := time.NewTimer(30 * time.Second)
	defer timeout.Stop()

	for {
		result, err := client.Exec(ctx, machine, argv)
		if err == nil && result.ExitCode == 0 {
			return result, nil
		}
		if err != nil {
			lastErr = err
		} else {
			lastErr = fmt.Errorf(
				"remote command exited with code %d: %s",
				result.ExitCode,
				strings.TrimSpace(result.Stderr),
			)
		}

		select {
		case <-ctx.Done():
			return compute.ExecResult{}, ctx.Err()
		case <-timeout.C:
			return compute.ExecResult{}, fmt.Errorf(
				"machine %q did not become executable: %w",
				machine.Name,
				lastErr,
			)
		case <-ticker.C:
		}
	}
}

func cleanupPair(t *testing.T, client compute.Provider, pair compute.Pair) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err := pair.Cleanup(ctx, client); err != nil {
		t.Errorf("cleanup pair: %v", err)
	}
}

func removeMachine(t *testing.T, client compute.Provider, machine compute.Machine) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err := client.Remove(ctx, machine); err != nil {
		t.Errorf("remove machine %q: %v", machine.Name, err)
	}
}

func sanitizeProofID(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	var builder strings.Builder
	for _, char := range value {
		switch {
		case char >= 'a' && char <= 'z':
			builder.WriteRune(char)
		case char >= '0' && char <= '9':
			builder.WriteRune(char)
		case char == '-':
			builder.WriteRune(char)
		}
	}
	return strings.Trim(builder.String(), "-")
}
