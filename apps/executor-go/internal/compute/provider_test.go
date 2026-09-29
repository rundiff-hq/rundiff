package compute

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type fakeProvider struct {
	forkCount  int
	failForkAt int
	removed    []string
	removeErrs map[string]error
}

func (provider *fakeProvider) Fork(
	_ context.Context,
	_ string,
	childName string,
) (Machine, error) {
	provider.forkCount++
	if provider.failForkAt == provider.forkCount {
		return Machine{}, errors.New("fork failed")
	}
	return Machine{Name: childName}, nil
}

func (provider *fakeProvider) Exec(
	_ context.Context,
	_ Machine,
	_ []string,
) (ExecResult, error) {
	return ExecResult{}, nil
}

func (provider *fakeProvider) Remove(_ context.Context, machine Machine) error {
	provider.removed = append(provider.removed, machine.Name)
	if provider.removeErrs == nil {
		return nil
	}
	return provider.removeErrs[machine.Name]
}

func TestForkPairRemovesBaselineWhenCandidateForkFails(t *testing.T) {
	provider := &fakeProvider{failForkAt: 2}

	_, err := ForkPair(
		context.Background(),
		provider,
		"golden",
		"baseline",
		"candidate",
	)

	if err == nil {
		t.Fatal("expected fork error")
	}
	if !reflect.DeepEqual(provider.removed, []string{"baseline"}) {
		t.Fatalf("removed = %#v, want baseline cleanup", provider.removed)
	}
}

func TestPairCleanupAttemptsBothChildren(t *testing.T) {
	provider := &fakeProvider{
		removeErrs: map[string]error{
			"candidate": errors.New("candidate cleanup failed"),
			"baseline":  errors.New("baseline cleanup failed"),
		},
	}
	pair := Pair{
		Baseline:  Machine{Name: "baseline"},
		Candidate: Machine{Name: "candidate"},
	}

	err := pair.Cleanup(context.Background(), provider)

	if err == nil {
		t.Fatal("expected joined cleanup error")
	}
	if !reflect.DeepEqual(provider.removed, []string{"candidate", "baseline"}) {
		t.Fatalf("removed = %#v, want candidate then baseline", provider.removed)
	}
}


type fakePairForkProvider struct {
	fakeProvider
	pairCalls int
}

func (provider *fakePairForkProvider) ForkPair(
	_ context.Context,
	_ string,
	baselineName string,
	candidateName string,
) (Pair, error) {
	provider.pairCalls++
	return Pair{
		Baseline:  Machine{Name: baselineName},
		Candidate: Machine{Name: candidateName},
	}, nil
}

func TestForkPairUsesProviderPairCapabilityWhenAvailable(t *testing.T) {
	provider := &fakePairForkProvider{}

	pair, err := ForkPair(
		context.Background(),
		provider,
		"golden",
		"baseline",
		"candidate",
	)
	if err != nil {
		t.Fatalf("ForkPair returned error: %v", err)
	}
	if provider.pairCalls != 1 {
		t.Fatalf("pair calls = %d, want 1", provider.pairCalls)
	}
	if provider.forkCount != 0 {
		t.Fatalf("fallback fork calls = %d, want 0", provider.forkCount)
	}
	if pair.Baseline.Name != "baseline" || pair.Candidate.Name != "candidate" {
		t.Fatalf("unexpected pair: %#v", pair)
	}
}
