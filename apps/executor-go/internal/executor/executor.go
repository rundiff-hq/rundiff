package executor

import (
	"context"
	"fmt"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

type Phase string

const (
	PhasePrepare   Phase = "Prepare"
	PhaseClone     Phase = "Clone"
	PhaseBootstrap Phase = "Bootstrap"
	PhaseBuild     Phase = "Build"
	PhaseStart     Phase = "Start"
	PhaseReady     Phase = "Ready"
	PhaseScenario  Phase = "Scenario"
	PhaseCollect   Phase = "Collect"
	PhaseTeardown  Phase = "Teardown"
)

type Runner interface {
	Run(context.Context, protocol.RequestV1, journal.Recorder) (protocol.ResultV1, error)
}

type Executor struct {
	journal journal.Recorder
	runner  Runner
}

func New(recorder journal.Recorder, runner Runner) *Executor {
	return &Executor{journal: recorder, runner: runner}
}

func (e *Executor) Execute(ctx context.Context, request protocol.RequestV1) (protocol.ResultV1, error) {
	if err := request.Validate(); err != nil {
		return protocol.ResultV1{}, err
	}

	if err := e.phase(request, PhasePrepare, "phase_started", ""); err != nil {
		return protocol.ResultV1{}, err
	}
	if err := e.phase(request, PhasePrepare, "phase_completed", ""); err != nil {
		return protocol.ResultV1{}, err
	}

	if err := e.phase(request, PhaseScenario, "phase_started", ""); err != nil {
		return protocol.ResultV1{}, err
	}

	result, runErr := e.runner.Run(ctx, request, e.journal)
	if runErr != nil {
		result = protocol.Failed("RunDiff::Executor::GoSupervisorError", runErr.Error())
	}

	if err := e.phase(request, PhaseScenario, "phase_completed", "status="+result.Status); err != nil {
		return protocol.ResultV1{}, err
	}

	if err := e.phase(request, PhaseCollect, "phase_started", ""); err != nil {
		return protocol.ResultV1{}, err
	}
	if err := result.Validate(); err != nil {
		result = protocol.Failed("RunDiff::Executor::InvalidResult", err.Error())
	}
	if err := e.phase(request, PhaseCollect, "phase_completed", "status="+result.Status); err != nil {
		return protocol.ResultV1{}, err
	}

	if err := e.phase(request, PhaseTeardown, "phase_started", ""); err != nil {
		return protocol.ResultV1{}, err
	}
	if err := e.phase(request, PhaseTeardown, "phase_completed", ""); err != nil {
		return protocol.ResultV1{}, err
	}

	return result, nil
}

func (e *Executor) phase(request protocol.RequestV1, phase Phase, kind, message string) error {
	if e.journal == nil {
		return fmt.Errorf("resource journal recorder is required")
	}
	return e.journal.Append(journal.Entry{
		Kind:          kind,
		ExecutionID:   request.ExecutionID,
		AttemptNumber: request.AttemptNumber,
		Phase:         string(phase),
		Message:       message,
	})
}
