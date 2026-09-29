package boxd

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute/golden"
)

type fakeGoldenProvider struct {
	machines    map[string]compute.Machine
	markers     map[string]bool
	createCount int
	removeCount int
	getErr      error
}

func newFakeGoldenProvider() *fakeGoldenProvider {
	return &fakeGoldenProvider{
		machines: map[string]compute.Machine{},
		markers:  map[string]bool{},
	}
}

func (provider *fakeGoldenProvider) Get(
	_ context.Context,
	name string,
) (compute.Machine, error) {
	if provider.getErr != nil {
		return compute.Machine{}, provider.getErr
	}
	machine, ok := provider.machines[name]
	if !ok {
		return compute.Machine{}, ErrMachineNotFound
	}
	return machine, nil
}

func (provider *fakeGoldenProvider) Create(
	_ context.Context,
	name string,
	_ bool,
) (compute.Machine, error) {
	provider.createCount++
	machine := compute.Machine{Name: name}
	provider.machines[name] = machine
	return machine, nil
}

func (provider *fakeGoldenProvider) Exec(
	_ context.Context,
	machine compute.Machine,
	argv []string,
) (compute.ExecResult, error) {
	if len(argv) == 0 {
		return compute.ExecResult{}, errors.New("empty argv")
	}
	switch argv[0] {
	case "mkdir":
		return compute.ExecResult{}, nil
	case "touch":
		if len(argv) != 2 {
			return compute.ExecResult{}, errors.New("unexpected touch argv")
		}
		provider.markers[machine.Name+"|"+argv[1]] = true
		return compute.ExecResult{}, nil
	case "test":
		if len(argv) != 3 || argv[1] != "-f" {
			return compute.ExecResult{}, errors.New("unexpected test argv")
		}
		if provider.markers[machine.Name+"|"+argv[2]] {
			return compute.ExecResult{}, nil
		}
		return compute.ExecResult{ExitCode: 1}, nil
	default:
		return compute.ExecResult{}, nil
	}
}

func (provider *fakeGoldenProvider) Remove(
	_ context.Context,
	machine compute.Machine,
) error {
	provider.removeCount++
	delete(provider.machines, machine.Name)
	prefix := machine.Name + "|"
	for key := range provider.markers {
		if strings.HasPrefix(key, prefix) {
			delete(provider.markers, key)
		}
	}
	return nil
}

func goldenTestSpec() golden.Spec {
	return golden.Spec{
		Provider:              "boxd",
		BaseImage:             "ubuntu-24.04",
		Repository:            "rundiff-hq/example-node-express-postgres",
		TrustedSource:         "e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb",
		ToolRevision:          "tool-sha",
		RuntimeIdentity:       "node-24+npm-11",
		DependencyLockDigest:  "lock-sha256",
		ServiceTopologyDigest: "postgres17+node-http-v1",
	}
}

func TestGoldenManagerCreatesThenReusesReadyGolden(t *testing.T) {
	provider := newFakeGoldenProvider()
	manager := GoldenManager{Provider: provider, MarkerRoot: "/golden"}
	prepareCount := 0
	prepare := func(_ context.Context, _ compute.Machine) error {
		prepareCount++
		return nil
	}

	first, err := manager.Ensure(context.Background(), goldenTestSpec(), prepare)
	if err != nil {
		t.Fatalf("first Ensure returned error: %v", err)
	}
	if first.Reused {
		t.Fatal("first Ensure unexpectedly reused machine")
	}

	second, err := manager.Ensure(context.Background(), goldenTestSpec(), prepare)
	if err != nil {
		t.Fatalf("second Ensure returned error: %v", err)
	}
	if !second.Reused {
		t.Fatal("second Ensure did not reuse ready machine")
	}
	if first.Machine.Name != second.Machine.Name {
		t.Fatalf("machine changed: %q != %q", first.Machine.Name, second.Machine.Name)
	}
	if prepareCount != 1 {
		t.Fatalf("prepare count = %d, want 1", prepareCount)
	}
	if provider.createCount != 1 {
		t.Fatalf("create count = %d, want 1", provider.createCount)
	}
	if provider.removeCount != 0 {
		t.Fatalf("remove count = %d, want 0", provider.removeCount)
	}
}

func TestGoldenManagerCleansUpFailedPreparation(t *testing.T) {
	provider := newFakeGoldenProvider()
	manager := GoldenManager{Provider: provider}

	_, err := manager.Ensure(
		context.Background(),
		goldenTestSpec(),
		func(context.Context, compute.Machine) error {
			return errors.New("prepare failed")
		},
	)
	if err == nil {
		t.Fatal("expected prepare error")
	}
	if provider.createCount != 1 {
		t.Fatalf("create count = %d, want 1", provider.createCount)
	}
	if provider.removeCount != 1 {
		t.Fatalf("remove count = %d, want 1", provider.removeCount)
	}
	if len(provider.machines) != 0 {
		t.Fatalf("machines leaked: %#v", provider.machines)
	}
}

func TestGoldenManagerRefreshesExistingMachineWithoutReadyMarker(t *testing.T) {
	provider := newFakeGoldenProvider()
	manager := GoldenManager{Provider: provider, MarkerRoot: "/golden"}
	fingerprint, err := goldenTestSpec().Fingerprint()
	if err != nil {
		t.Fatal(err)
	}
	name := golden.MachineName(fingerprint)
	provider.machines[name] = compute.Machine{Name: name}

	prepareCount := 0
	result, err := manager.Ensure(
		context.Background(),
		goldenTestSpec(),
		func(context.Context, compute.Machine) error {
			prepareCount++
			return nil
		},
	)
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	if result.Reused {
		t.Fatal("invalid existing golden was reused")
	}
	if provider.removeCount != 1 || provider.createCount != 1 {
		t.Fatalf(
			"refresh counts remove/create = %d/%d, want 1/1",
			provider.removeCount,
			provider.createCount,
		)
	}
	if prepareCount != 1 {
		t.Fatalf("prepare count = %d, want 1", prepareCount)
	}
}

func TestGoldenManagerDoesNotTurnLookupFailureIntoCreate(t *testing.T) {
	provider := newFakeGoldenProvider()
	provider.getErr = errors.New("authentication failed")
	manager := GoldenManager{Provider: provider}

	_, err := manager.Ensure(
		context.Background(),
		goldenTestSpec(),
		func(context.Context, compute.Machine) error { return nil },
	)
	if err == nil {
		t.Fatal("expected lookup error")
	}
	if provider.createCount != 0 {
		t.Fatalf("create count = %d, want 0", provider.createCount)
	}
}
