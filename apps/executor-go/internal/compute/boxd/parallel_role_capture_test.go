package boxd

import (
	"context"
	"errors"
	"testing"
	"time"
)

type roleCaptureResult struct {
	Role     string
	Body     []byte
	Elapsed  time.Duration
	Err      error
}

type pairedCaptureResult struct {
	Baseline  roleCaptureResult
	Candidate roleCaptureResult
	Critical  time.Duration
}

func runParallelRoleCaptures(
	ctx context.Context,
	baseline func(context.Context) ([]byte, error),
	candidate func(context.Context) ([]byte, error),
) pairedCaptureResult {
	type result struct {
		role    string
		body    []byte
		elapsed time.Duration
		err     error
	}
	results := make(chan result, 2)
	started := time.Now()

	go func() {
		roleStarted := time.Now()
		body, err := baseline(ctx)
		results <- result{
			role:    "baseline",
			body:    body,
			elapsed: time.Since(roleStarted),
			err:     err,
		}
	}()

	go func() {
		roleStarted := time.Now()
		body, err := candidate(ctx)
		results <- result{
			role:    "candidate",
			body:    body,
			elapsed: time.Since(roleStarted),
			err:     err,
		}
	}()

	pair := pairedCaptureResult{}
	for range 2 {
		item := <-results
		roleResult := roleCaptureResult{
			Role:    item.role,
			Body:    item.body,
			Elapsed: item.elapsed,
			Err:     item.err,
		}
		if item.role == "baseline" {
			pair.Baseline = roleResult
		} else {
			pair.Candidate = roleResult
		}
	}
	pair.Critical = time.Since(started)
	return pair
}

func TestRunParallelRoleCapturesOverlapsBothRoles(t *testing.T) {
	started := make(chan string, 2)
	release := make(chan struct{})

	capture := func(role string) func(context.Context) ([]byte, error) {
		return func(ctx context.Context) ([]byte, error) {
			started <- role
			select {
			case <-release:
				return []byte(role), nil
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}

	done := make(chan pairedCaptureResult, 1)
	go func() {
		done <- runParallelRoleCaptures(
			context.Background(),
			capture("baseline"),
			capture("candidate"),
		)
	}()

	seen := map[string]bool{}
	for range 2 {
		select {
		case role := <-started:
			seen[role] = true
		case <-time.After(time.Second):
			t.Fatal("both role captures did not start concurrently")
		}
	}
	if !seen["baseline"] || !seen["candidate"] {
		t.Fatalf("started roles = %#v, want both", seen)
	}

	close(release)
	result := <-done
	if result.Baseline.Err != nil || result.Candidate.Err != nil {
		t.Fatalf(
			"capture errors baseline/candidate = %v/%v",
			result.Baseline.Err,
			result.Candidate.Err,
		)
	}
	if string(result.Baseline.Body) != "baseline" ||
		string(result.Candidate.Body) != "candidate" {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestRunParallelRoleCapturesCollectsBothErrorsAfterCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan struct{}, 2)
	capture := func(context.Context) ([]byte, error) {
		started <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}

	done := make(chan pairedCaptureResult, 1)
	go func() {
		done <- runParallelRoleCaptures(ctx, capture, capture)
	}()

	<-started
	<-started
	cancel()

	result := <-done
	if !errors.Is(result.Baseline.Err, context.Canceled) {
		t.Fatalf("baseline error = %v, want context canceled", result.Baseline.Err)
	}
	if !errors.Is(result.Candidate.Err, context.Canceled) {
		t.Fatalf("candidate error = %v, want context canceled", result.Candidate.Err)
	}
}
