package agent

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/controlplane"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/repositorycapability"
)

var ErrAttemptNoLongerLive = errors.New("execution attempt is no longer live")

type ControlPlane interface {
	Claim(context.Context, controlplane.Assignment) (controlplane.Claim, error)
	Heartbeat(context.Context, controlplane.Assignment) (controlplane.Heartbeat, error)
	SubmitResult(
		context.Context,
		controlplane.Assignment,
		protocol.ResultV1,
	) (controlplane.Submission, error)
}

type Engine interface {
	Execute(context.Context, protocol.RequestV1) (protocol.ResultV1, error)
}

type Agent struct {
	ControlPlane      ControlPlane
	Engine            Engine
	Journal           journal.Recorder
	HeartbeatInterval time.Duration
	Now               func() time.Time
}

type Outcome struct {
	Request    protocol.RequestV1
	Result     protocol.ResultV1
	Submission controlplane.Submission
}

func (a *Agent) Run(
	ctx context.Context,
	assignment controlplane.Assignment,
) (Outcome, error) {
	if a.ControlPlane == nil || a.Engine == nil || a.Journal == nil {
		return Outcome{}, errors.New("agent dependencies are required")
	}

	claim, err := a.ControlPlane.Claim(ctx, assignment)
	if err != nil {
		return Outcome{}, fmt.Errorf("claim exact attempt: %w", err)
	}
	if err := a.append(claim.Request, "lease_claimed", claim.LeaseExpiresAt.Format(time.RFC3339Nano)); err != nil {
		return Outcome{}, err
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	runCtx = repositorycapability.WithToken(runCtx, claim.RepositoryCapability)

	type executionResult struct {
		result protocol.ResultV1
		err    error
	}
	done := make(chan executionResult, 1)
	go func() {
		result, runErr := a.Engine.Execute(runCtx, claim.Request)
		done <- executionResult{result: result, err: runErr}
	}()

	interval := a.HeartbeatInterval
	if interval <= 0 {
		interval = 20 * time.Second
	}
	now := a.Now
	if now == nil {
		now = time.Now
	}

	leaseExpiresAt := claim.LeaseExpiresAt
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var terminalStatus string
	var terminalReason string
	var once sync.Once

	stopForLease := func(status, reason string) {
		once.Do(func() {
			terminalStatus = status
			terminalReason = reason
			cancel()
		})
	}

	for {
		select {
		case executed := <-done:
			if terminalStatus != "" {
				_ = a.append(
					claim.Request,
					"lease_lost",
					terminalStatus+":"+terminalReason,
				)
				return Outcome{Request: claim.Request, Result: executed.result}, fmt.Errorf(
					"%w: %s",
					ErrAttemptNoLongerLive,
					terminalStatus,
				)
			}
			if executed.err != nil {
				executed.result = protocol.Failed(
					"RunDiff::Executor::GoSupervisorError",
					executed.err.Error(),
				)
			}
			submission, submitErr := a.ControlPlane.SubmitResult(
				ctx,
				assignment,
				executed.result,
			)
			if submitErr != nil {
				return Outcome{Request: claim.Request, Result: executed.result}, fmt.Errorf(
					"submit result: %w",
					submitErr,
				)
			}
			if err := a.append(
				claim.Request,
				"result_submitted",
				submission.Status,
			); err != nil {
				return Outcome{}, err
			}
			return Outcome{
				Request:    claim.Request,
				Result:     executed.result,
				Submission: submission,
			}, nil

		case <-ticker.C:
			heartbeat, heartbeatErr := a.ControlPlane.Heartbeat(ctx, assignment)
			if heartbeatErr != nil {
				if !now().Before(leaseExpiresAt) {
					stopForLease("expired", "heartbeat_transport_lost")
				}
				continue
			}

			switch heartbeat.Status {
			case "live":
				if heartbeat.LeaseExpiresAt == nil {
					stopForLease("not_live", "heartbeat_missing_lease_expiry")
					continue
				}
				renewed, parseErr := time.Parse(time.RFC3339Nano, *heartbeat.LeaseExpiresAt)
				if parseErr != nil {
					stopForLease("not_live", "heartbeat_invalid_lease_expiry")
					continue
				}
				leaseExpiresAt = renewed
				_ = a.append(claim.Request, "lease_renewed", renewed.Format(time.RFC3339Nano))
			case "cancelled", "superseded", "expired", "not_live":
				reason := heartbeat.Status
				if heartbeat.CancellationReason != nil {
					reason = *heartbeat.CancellationReason
				}
				stopForLease(heartbeat.Status, reason)
			default:
				stopForLease("not_live", "unknown_heartbeat_status")
			}

		case <-ctx.Done():
			cancel()
			executed := <-done
			return Outcome{Request: claim.Request, Result: executed.result}, ctx.Err()
		}
	}
}

func (a *Agent) append(
	request protocol.RequestV1,
	kind string,
	message string,
) error {
	return a.Journal.Append(journal.Entry{
		Kind:          kind,
		ExecutionID:   request.ExecutionID,
		AttemptNumber: request.AttemptNumber,
		Message:       message,
	})
}
