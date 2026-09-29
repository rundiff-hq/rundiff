package boxd

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute/golden"
)

func TestLivePersistentGoldenReuseSession(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd session proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd session proof")
	}
	toolSHA := os.Getenv("RUNDIFF_BOXD_TOOL_SHA")
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for the live Boxd session proof")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	client, err := NewSessionSDK("node", "sdkbridge/session.mjs")
	if err != nil {
		t.Fatalf("start SDK session: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close SDK session: %v", closeErr)
		}
	}()

	spec := golden.Spec{
		Provider:              "boxd",
		BaseImage:             "boxd-default-ubuntu-24.04",
		Repository:            "rundiff-hq/rundiff",
		TrustedSource:         toolSHA,
		ToolRevision:          toolSHA,
		RuntimeIdentity:       "boxd-session-live-proof-v1",
		DependencyLockDigest:  "none-live-proof-v1",
		ServiceTopologyDigest: "persistent-golden-session-v1",
	}
	fingerprint, err := spec.Fingerprint()
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	name := golden.MachineName(fingerprint)

	if existing, getErr := client.Get(ctx, name); getErr == nil {
		if removeErr := client.Remove(ctx, existing); removeErr != nil {
			t.Fatalf("remove stale session test golden: %v", removeErr)
		}
	} else if !errors.Is(getErr, ErrMachineNotFound) {
		t.Fatalf("lookup stale session test golden: %v", getErr)
	}

	manager := GoldenManager{Provider: client}
	prepareCount := 0
	prepare := func(ctx context.Context, machine compute.Machine) error {
		prepareCount++
		result, execErr := client.Exec(
			ctx,
			machine,
			[]string{"touch", "/tmp/rundiff-persistent-golden-session-proof"},
		)
		if execErr != nil {
			return execErr
		}
		if result.ExitCode != 0 {
			return errors.New("session golden preparation command failed")
		}
		return nil
	}

	createStarted := time.Now()
	first, err := manager.Ensure(ctx, spec, prepare)
	if err != nil {
		t.Fatalf("first session Ensure: %v", err)
	}
	t.Logf(
		"golden.session.ensure.create_ms=%d",
		time.Since(createStarted).Milliseconds(),
	)
	defer removeMachine(t, client, first.Machine)

	if first.Reused {
		t.Fatal("first session Ensure unexpectedly reused golden")
	}

	reuseOneStarted := time.Now()
	second, err := manager.Ensure(ctx, spec, prepare)
	if err != nil {
		t.Fatalf("second session Ensure: %v", err)
	}
	t.Logf(
		"golden.session.ensure.reuse_1_ms=%d",
		time.Since(reuseOneStarted).Milliseconds(),
	)
	if !second.Reused {
		t.Fatal("second session Ensure did not reuse golden")
	}

	reuseTwoStarted := time.Now()
	third, err := manager.Ensure(ctx, spec, prepare)
	if err != nil {
		t.Fatalf("third session Ensure: %v", err)
	}
	t.Logf(
		"golden.session.ensure.reuse_2_ms=%d",
		time.Since(reuseTwoStarted).Milliseconds(),
	)
	if !third.Reused {
		t.Fatal("third session Ensure did not reuse golden")
	}

	if prepareCount != 1 {
		t.Fatalf("prepare count = %d, want 1", prepareCount)
	}
	if first.Machine.Name != second.Machine.Name ||
		second.Machine.Name != third.Machine.Name {
		t.Fatalf(
			"session golden changed: %q %q %q",
			first.Machine.Name,
			second.Machine.Name,
			third.Machine.Name,
		)
	}

	proof, err := client.Exec(
		ctx,
		third.Machine,
		[]string{"test", "-f", "/tmp/rundiff-persistent-golden-session-proof"},
	)
	if err != nil {
		t.Fatalf("verify session prepared state: %v", err)
	}
	if proof.ExitCode != 0 {
		t.Fatalf("session prepared state missing, exit=%d", proof.ExitCode)
	}

	t.Log("golden.session.persistent_reuse=ok")
}
