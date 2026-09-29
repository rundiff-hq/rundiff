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

func TestLivePersistentGoldenReuse(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd golden proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd golden proof")
	}
	toolSHA := os.Getenv("RUNDIFF_BOXD_TOOL_SHA")
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for the live Boxd golden proof")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	client := NewSDK("node", "sdkbridge/bridge.mjs")
	spec := golden.Spec{
		Provider:              "boxd",
		BaseImage:             "boxd-default-ubuntu-24.04",
		Repository:            "rundiff-hq/rundiff",
		TrustedSource:         toolSHA,
		ToolRevision:          toolSHA,
		RuntimeIdentity:       "boxd-default-live-proof-v1",
		DependencyLockDigest:  "none-live-proof-v1",
		ServiceTopologyDigest: "persistent-golden-manager-v1",
	}
	fingerprint, err := spec.Fingerprint()
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	name := golden.MachineName(fingerprint)

	if existing, getErr := client.Get(ctx, name); getErr == nil {
		if removeErr := client.Remove(ctx, existing); removeErr != nil {
			t.Fatalf("remove stale test golden: %v", removeErr)
		}
	} else if !errors.Is(getErr, ErrMachineNotFound) {
		t.Fatalf("lookup stale test golden: %v", getErr)
	}

	manager := GoldenManager{Provider: client}
	prepareCount := 0
	prepare := func(ctx context.Context, machine compute.Machine) error {
		prepareCount++
		result, execErr := client.Exec(
			ctx,
			machine,
			[]string{"touch", "/tmp/rundiff-persistent-golden-proof"},
		)
		if execErr != nil {
			return execErr
		}
		if result.ExitCode != 0 {
			return errors.New("golden preparation command failed")
		}
		return nil
	}

	firstStarted := time.Now()
	first, err := manager.Ensure(ctx, spec, prepare)
	if err != nil {
		t.Fatalf("first Ensure: %v", err)
	}
	t.Logf("golden.ensure.create_ms=%d", time.Since(firstStarted).Milliseconds())
	defer removeMachine(t, client, first.Machine)

	if first.Reused {
		t.Fatal("first Ensure unexpectedly reused golden")
	}

	secondStarted := time.Now()
	second, err := manager.Ensure(ctx, spec, prepare)
	if err != nil {
		t.Fatalf("second Ensure: %v", err)
	}
	t.Logf("golden.ensure.reuse_ms=%d", time.Since(secondStarted).Milliseconds())

	if !second.Reused {
		t.Fatal("second Ensure did not reuse persistent golden")
	}
	if first.Machine.Name != second.Machine.Name {
		t.Fatalf(
			"golden machine changed: first=%q second=%q",
			first.Machine.Name,
			second.Machine.Name,
		)
	}
	if prepareCount != 1 {
		t.Fatalf("prepare count = %d, want 1", prepareCount)
	}

	proof, err := client.Exec(
		ctx,
		second.Machine,
		[]string{"test", "-f", "/tmp/rundiff-persistent-golden-proof"},
	)
	if err != nil {
		t.Fatalf("verify prepared state: %v", err)
	}
	if proof.ExitCode != 0 {
		t.Fatalf("prepared state missing after reuse, exit=%d", proof.ExitCode)
	}

	t.Logf("golden.fingerprint=%s", fingerprint)
	t.Log("golden.persistent_reuse=ok")
}
