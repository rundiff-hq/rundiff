package boxd

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

type fakePairSDKClient struct {
	started chan<- string
	release <-chan struct{}
	forkErr error

	mu         sync.Mutex
	closeCount int
}

func (client *fakePairSDKClient) Create(
	_ context.Context,
	name string,
	_ bool,
) (compute.Machine, error) {
	return compute.Machine{Name: name}, nil
}

func (client *fakePairSDKClient) Get(
	_ context.Context,
	name string,
) (compute.Machine, error) {
	return compute.Machine{Name: name}, nil
}

func (client *fakePairSDKClient) Fork(
	ctx context.Context,
	_ string,
	childName string,
) (compute.Machine, error) {
	if client.started != nil {
		client.started <- childName
	}
	if client.release != nil {
		select {
		case <-client.release:
		case <-ctx.Done():
			return compute.Machine{}, ctx.Err()
		}
	}
	if client.forkErr != nil {
		return compute.Machine{}, client.forkErr
	}
	return compute.Machine{Name: childName}, nil
}

func (client *fakePairSDKClient) Exec(
	_ context.Context,
	_ compute.Machine,
	_ []string,
) (compute.ExecResult, error) {
	return compute.ExecResult{}, nil
}

func (client *fakePairSDKClient) Remove(
	_ context.Context,
	_ compute.Machine,
) error {
	return nil
}

func (client *fakePairSDKClient) Close() error {
	client.mu.Lock()
	defer client.mu.Unlock()
	client.closeCount++
	return nil
}

func (client *fakePairSDKClient) closes() int {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.closeCount
}

type fakePairRemover struct {
	mu      sync.Mutex
	removed []string
	closed  int
}

func (remover *fakePairRemover) Remove(
	_ context.Context,
	machine compute.Machine,
) error {
	remover.mu.Lock()
	defer remover.mu.Unlock()
	remover.removed = append(remover.removed, machine.Name)
	return nil
}

func (remover *fakePairRemover) Close() error {
	remover.mu.Lock()
	defer remover.mu.Unlock()
	remover.closed++
	return nil
}

func (remover *fakePairRemover) snapshot() ([]string, int) {
	remover.mu.Lock()
	defer remover.mu.Unlock()
	return append([]string(nil), remover.removed...), remover.closed
}

func TestPairSDKForkPairStartsBothForksBeforeEitherCompletes(t *testing.T) {
	started := make(chan string, 2)
	release := make(chan struct{})
	primary := &fakePairSDKClient{started: started, release: release}
	secondary := &fakePairSDKClient{started: started, release: release}
	client := &PairSDK{
		primary:   primary,
		secondary: secondary,
		cleanupFactory: func() machineRemover {
			return &fakePairRemover{}
		},
	}

	type result struct {
		pair compute.Pair
		err  error
	}
	done := make(chan result, 1)
	go func() {
		pair, err := client.ForkPair(
			context.Background(),
			"golden",
			"baseline",
			"candidate",
		)
		done <- result{pair: pair, err: err}
	}()

	seen := map[string]bool{}
	for range 2 {
		select {
		case name := <-started:
			seen[name] = true
		case <-time.After(time.Second):
			t.Fatal("both fork calls did not start concurrently")
		}
	}
	if !seen["baseline"] || !seen["candidate"] {
		t.Fatalf("started = %#v, want both roles", seen)
	}

	close(release)
	got := <-done
	if got.err != nil {
		t.Fatalf("ForkPair returned error: %v", got.err)
	}
	if got.pair.Baseline.Name != "baseline" ||
		got.pair.Candidate.Name != "candidate" {
		t.Fatalf("unexpected pair: %#v", got.pair)
	}
}

func TestPairSDKForkPairCleansBothNamesAfterPartialFailure(t *testing.T) {
	remover := &fakePairRemover{}
	client := &PairSDK{
		primary:   &fakePairSDKClient{},
		secondary: &fakePairSDKClient{forkErr: errors.New("candidate failed")},
		cleanupFactory: func() machineRemover {
			return remover
		},
	}

	_, err := client.ForkPair(
		context.Background(),
		"golden",
		"baseline",
		"candidate",
	)
	if err == nil {
		t.Fatal("expected pair fork error")
	}

	removed, closed := remover.snapshot()
	if !reflect.DeepEqual(removed, []string{"baseline", "candidate"}) {
		t.Fatalf("removed = %#v, want both deterministic child names", removed)
	}
	if closed != 1 {
		t.Fatalf("cleanup provider close count = %d, want 1", closed)
	}
}

func TestPairSDKForkPairCleansBothNamesAfterCancellation(t *testing.T) {
	started := make(chan string, 2)
	release := make(chan struct{})
	remover := &fakePairRemover{}
	client := &PairSDK{
		primary:   &fakePairSDKClient{started: started, release: release},
		secondary: &fakePairSDKClient{started: started, release: release},
		cleanupFactory: func() machineRemover {
			return remover
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := client.ForkPair(ctx, "golden", "baseline", "candidate")
		done <- err
	}()

	for range 2 {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("forks did not both start before cancellation")
		}
	}
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("ForkPair error = %v, want context canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("ForkPair did not return after cancellation")
	}

	removed, _ := remover.snapshot()
	if !reflect.DeepEqual(removed, []string{"baseline", "candidate"}) {
		t.Fatalf("removed = %#v, want both deterministic child names", removed)
	}
}

func TestPairSDKCloseClosesBothSessions(t *testing.T) {
	primary := &fakePairSDKClient{}
	secondary := &fakePairSDKClient{}
	client := &PairSDK{
		primary:   primary,
		secondary: secondary,
	}

	if err := client.Close(); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if primary.closes() != 1 || secondary.closes() != 1 {
		t.Fatalf(
			"close counts primary/secondary = %d/%d, want 1/1",
			primary.closes(),
			secondary.closes(),
		)
	}
}
