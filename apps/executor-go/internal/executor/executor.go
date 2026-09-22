package executor

import (
	"context"
	"fmt"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/metrics"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/workspace"
)

type Phase string

const (
	PhasePrepare        Phase = "Prepare"
	PhaseClone          Phase = "Clone"
	PhaseBootstrap      Phase = "Bootstrap"
	PhaseSubjectPrepare Phase = "SubjectPrepare"
	PhaseBuild          Phase = "Build"
	PhaseStart          Phase = "Start"
	PhaseReady          Phase = "Ready"
	PhaseStop           Phase = "Stop"
	PhaseScenario       Phase = "Scenario"
	PhaseCollect        Phase = "Collect"
	PhaseTeardown       Phase = "Teardown"
)

type Runner interface {
	Run(
		context.Context,
		protocol.RequestV1,
		workspace.Prepared,
		journal.Recorder,
	) (protocol.ResultV1, error)
}

type Bootstrapper interface {
	Bootstrap(
		context.Context,
		string,
		string,
	) (map[string]string, error)
}

type SubjectPreparer interface {
	Prepare(
		context.Context,
		protocol.RequestV1,
		string,
		string,
		map[string]string,
	) (map[string]string, error)
}

type ServiceController interface {
	Start(
		context.Context,
		protocol.RequestV1,
		string,
		string,
		map[string]string,
		journal.Recorder,
	) (any, map[string]string, error)
	Ready(
		context.Context,
		protocol.RequestV1,
		string,
		string,
		map[string]string,
		any,
	) error
	Stop(
		context.Context,
		protocol.RequestV1,
		string,
		string,
		map[string]string,
		any,
		journal.Recorder,
	) error
}

type Builder interface {
	Build(
		context.Context,
		string,
		string,
		map[string]string,
	) error
}

type Executor struct {
	journal           journal.Recorder
	metrics           metrics.Recorder
	runner            Runner
	workspace         workspace.Manager
	bootstrapper      Bootstrapper
	subjectPrepare    SubjectPreparer
	serviceController ServiceController
	builder           Builder
}

func New(recorder journal.Recorder, runner Runner) *Executor {
	return &Executor{
		journal: recorder,
		metrics: metrics.Nop{},
		runner:  runner,
	}
}

func NewManaged(
	recorder journal.Recorder,
	phaseMetrics metrics.Recorder,
	runner Runner,
	manager workspace.Manager,
) *Executor {
	if phaseMetrics == nil {
		phaseMetrics = metrics.Nop{}
	}
	return &Executor{
		journal:   recorder,
		metrics:   phaseMetrics,
		runner:    runner,
		workspace: manager,
	}
}

func (e *Executor) WithBootstrapper(bootstrapper Bootstrapper) *Executor {
	e.bootstrapper = bootstrapper
	return e
}

func (e *Executor) WithSubjectPreparer(
	subjectPreparer SubjectPreparer,
) *Executor {
	e.subjectPrepare = subjectPreparer
	return e
}

func (e *Executor) WithServiceController(
	serviceController ServiceController,
) *Executor {
	e.serviceController = serviceController
	return e
}

func (e *Executor) WithBuilder(builder Builder) *Executor {
	e.builder = builder
	return e
}

func (e *Executor) Execute(
	ctx context.Context,
	request protocol.RequestV1,
) (result protocol.ResultV1, err error) {
	if err := request.Validate(); err != nil {
		return protocol.ResultV1{}, err
	}

	prepared := workspace.Prepared{}
	if e.workspace != nil {
		prepared, err = e.phaseWithPrepared(
			request,
			PhasePrepare,
			"go",
			"",
			func() (workspace.Prepared, error) {
				return e.workspace.Prepare(ctx, request, e.journal)
			},
		)
		if err != nil {
			return protocol.ResultV1{}, err
		}

		defer func() {
			cleanupCtx, cleanupCancel := context.WithTimeout(
				context.Background(),
				30*time.Second,
			)
			defer cleanupCancel()
			teardownErr := e.phaseForRole(
				request,
				PhaseTeardown,
				"go",
				"",
				func() error {
					return e.workspace.Teardown(
						cleanupCtx,
						request,
						prepared,
						e.journal,
					)
				},
			)
			if err == nil && teardownErr != nil {
				err = teardownErr
			}
		}()

		prepared, err = e.phaseWithPrepared(
			request,
			PhaseClone,
			"go",
			"",
			func() (workspace.Prepared, error) {
				return e.workspace.Clone(ctx, request, prepared, e.journal)
			},
		)
		if err != nil {
			return protocol.ResultV1{}, err
		}

		if e.bootstrapper != nil {
			prepared.BaselineEnvironment, err = e.phaseWithEnvironment(
				request,
				PhaseBootstrap,
				"go",
				"base",
				func() (map[string]string, error) {
					return e.bootstrapper.Bootstrap(
						ctx,
						"base",
						prepared.BaselineRoot,
					)
				},
			)
			if err != nil {
				return protocol.ResultV1{}, err
			}

			prepared.CandidateEnvironment, err = e.phaseWithEnvironment(
				request,
				PhaseBootstrap,
				"go",
				"candidate",
				func() (map[string]string, error) {
					return e.bootstrapper.Bootstrap(
						ctx,
						"candidate",
						prepared.CandidateRoot,
					)
				},
			)
			if err != nil {
				return protocol.ResultV1{}, err
			}
		}

		if e.subjectPrepare != nil {
			prepared.BaselineSubjectEnvironment, err =
				e.phaseWithEnvironment(
					request,
					PhaseSubjectPrepare,
					"go",
					"base",
					func() (map[string]string, error) {
						return e.subjectPrepare.Prepare(
							ctx,
							request,
							"base",
							prepared.BaselineRoot,
							prepared.BaselineEnvironment,
						)
					},
				)
			if err != nil {
				return protocol.ResultV1{}, err
			}

			prepared.CandidateSubjectEnvironment, err =
				e.phaseWithEnvironment(
					request,
					PhaseSubjectPrepare,
					"go",
					"candidate",
					func() (map[string]string, error) {
						return e.subjectPrepare.Prepare(
							ctx,
							request,
							"candidate",
							prepared.CandidateRoot,
							prepared.CandidateEnvironment,
						)
					},
				)
			if err != nil {
				return protocol.ResultV1{}, err
			}
		}

		if e.builder != nil {
			for _, subject := range []struct {
				role string
				root string
				env  map[string]string
			}{
				{
					role: "base",
					root: prepared.BaselineRoot,
					env:  prepared.BaselineEnvironment,
				},
				{
					role: "candidate",
					root: prepared.CandidateRoot,
					env:  prepared.CandidateEnvironment,
				},
			} {
				if err := e.phaseForRole(
					request,
					PhaseBuild,
					"go",
					subject.role,
					func() error {
						return e.builder.Build(
							ctx,
							subject.role,
							subject.root,
							subject.env,
						)
					},
				); err != nil {
					return protocol.ResultV1{}, err
				}
			}
		}

		if e.serviceController != nil {
			type activeService struct {
				role    string
				root    string
				env     map[string]string
				session any
			}
			activeServices := make([]activeService, 0, 2)
			defer func() {
				cleanupCtx, cleanupCancel := context.WithTimeout(
					context.Background(),
					30*time.Second,
				)
				defer cleanupCancel()

				for index := len(activeServices) - 1; index >= 0; index-- {
					service := activeServices[index]
					stopErr := e.phaseForRole(
						request,
						PhaseStop,
						"go",
						service.role,
						func() error {
							return e.serviceController.Stop(
								cleanupCtx,
								request,
								service.role,
								service.root,
								service.env,
								service.session,
								e.journal,
							)
						},
					)
					if err == nil && stopErr != nil {
						err = stopErr
					}
				}
			}()

			for _, subject := range []struct {
				role string
				root string
				env  *map[string]string
			}{
				{
					role: "base",
					root: prepared.BaselineRoot,
					env:  &prepared.BaselineSubjectEnvironment,
				},
				{
					role: "candidate",
					root: prepared.CandidateRoot,
					env:  &prepared.CandidateSubjectEnvironment,
				},
			} {
				session, serviceEnv, startErr := e.phaseWithServiceStart(
					request,
					subject.role,
					func() (any, map[string]string, error) {
						return e.serviceController.Start(
							ctx,
							request,
							subject.role,
							subject.root,
							*subject.env,
							e.journal,
						)
					},
				)
				if startErr != nil {
					return protocol.ResultV1{}, startErr
				}

				mergedEnv, mergeErr := mergeEnvironment(
					*subject.env,
					serviceEnv,
				)
				if mergeErr != nil {
					return protocol.ResultV1{}, mergeErr
				}
				*subject.env = mergedEnv
				activeServices = append(activeServices, activeService{
					role:    subject.role,
					root:    subject.root,
					env:     mergedEnv,
					session: session,
				})

				if readyErr := e.phaseForRole(
					request,
					PhaseReady,
					"go",
					subject.role,
					func() error {
						return e.serviceController.Ready(
							ctx,
							request,
							subject.role,
							subject.root,
							mergedEnv,
							session,
						)
					},
				); readyErr != nil {
					return protocol.ResultV1{}, readyErr
				}
			}

			prepared.ServicesPrepared = true
		}
	} else {
		if err := e.phase(
			request,
			PhasePrepare,
			"go-supervisor",
			func() error { return nil },
		); err != nil {
			return protocol.ResultV1{}, err
		}
		defer func() {
			teardownErr := e.phase(
				request,
				PhaseTeardown,
				"go-supervisor",
				func() error { return nil },
			)
			if err == nil && teardownErr != nil {
				err = teardownErr
			}
		}()
	}

	var runResult protocol.ResultV1
	if err := e.phase(
		request,
		PhaseScenario,
		runnerImplementation(e.runner),
		func() error {
			var runErr error
			runResult, runErr = e.runner.Run(ctx, request, prepared, e.journal)
			return runErr
		},
	); err != nil {
		runResult = protocol.Failed(
			"RunDiff::Executor::GoSupervisorError",
			err.Error(),
		)
	}

	result = runResult
	if collectErr := e.phase(
		request,
		PhaseCollect,
		"go-supervisor",
		func() error {
			if validationErr := result.Validate(); validationErr != nil {
				result = protocol.Failed(
					"RunDiff::Executor::InvalidResult",
					validationErr.Error(),
				)
			}
			return nil
		},
	); collectErr != nil {
		return protocol.ResultV1{}, collectErr
	}

	return result, nil
}

func (e *Executor) phase(
	request protocol.RequestV1,
	phase Phase,
	implementation string,
	call func() error,
) error {
	return e.phaseForRole(
		request,
		phase,
		implementation,
		"",
		call,
	)
}

func (e *Executor) phaseForRole(
	request protocol.RequestV1,
	phase Phase,
	implementation string,
	role string,
	call func() error,
) error {
	startedAt := time.Now()
	if err := e.journal.Append(journal.Entry{
		Kind:           "phase_started",
		ExecutionID:    request.ExecutionID,
		AttemptNumber:  request.AttemptNumber,
		Phase:          string(phase),
		Role:           role,
		Implementation: implementation,
	}); err != nil {
		return err
	}

	err := call()
	duration := time.Since(startedAt).Milliseconds()
	outcome := "ok"
	if err != nil {
		outcome = "error"
	}
	if metricErr := e.metrics.Record(metrics.Event{
		ExecutionID:    request.ExecutionID,
		AttemptNumber:  request.AttemptNumber,
		Implementation: implementation,
		Phase:          metricPhase(phase),
		Role:           role,
		DurationMillis: duration,
		Outcome:        outcome,
		ErrorClass:     errorClass(err),
	}); metricErr != nil && err == nil {
		err = metricErr
	}
	if journalErr := e.journal.Append(journal.Entry{
		Kind:           "phase_completed",
		ExecutionID:    request.ExecutionID,
		AttemptNumber:  request.AttemptNumber,
		Phase:          string(phase),
		Role:           role,
		Implementation: implementation,
		DurationMillis: duration,
		Outcome:        outcome,
	}); journalErr != nil && err == nil {
		err = journalErr
	}
	return err
}

func (e *Executor) phaseWithPrepared(
	request protocol.RequestV1,
	phase Phase,
	implementation string,
	role string,
	call func() (workspace.Prepared, error),
) (workspace.Prepared, error) {
	var value workspace.Prepared
	err := e.phaseForRole(
		request,
		phase,
		implementation,
		role,
		func() error {
			var callErr error
			value, callErr = call()
			return callErr
		},
	)
	return value, err
}

func (e *Executor) phaseWithServiceStart(
	request protocol.RequestV1,
	role string,
	call func() (any, map[string]string, error),
) (any, map[string]string, error) {
	var session any
	var environment map[string]string
	err := e.phaseForRole(
		request,
		PhaseStart,
		"go",
		role,
		func() error {
			var callErr error
			session, environment, callErr = call()
			return callErr
		},
	)
	return session, environment, err
}

func (e *Executor) phaseWithEnvironment(
	request protocol.RequestV1,
	phase Phase,
	implementation string,
	role string,
	call func() (map[string]string, error),
) (map[string]string, error) {
	var value map[string]string
	err := e.phaseForRole(
		request,
		phase,
		implementation,
		role,
		func() error {
			var callErr error
			value, callErr = call()
			return callErr
		},
	)
	return value, err
}

func metricPhase(phase Phase) string {
	switch phase {
	case PhasePrepare:
		return "prepare"
	case PhaseClone:
		return "clone"
	case PhaseBootstrap:
		return "bootstrap"
	case PhaseSubjectPrepare:
		return "subject_prepare"
	case PhaseBuild:
		return "build"
	case PhaseStart:
		return "start"
	case PhaseReady:
		return "ready"
	case PhaseStop:
		return "stop"
	case PhaseScenario:
		return "scenario"
	case PhaseCollect:
		return "collect"
	case PhaseTeardown:
		return "teardown"
	default:
		return string(phase)
	}
}

func errorClass(err error) string {
	if err == nil {
		return ""
	}
	return fmt.Sprintf("%T", err)
}

func mergeEnvironment(
	base map[string]string,
	additions map[string]string,
) (map[string]string, error) {
	result := make(map[string]string, len(base)+len(additions))
	for key, value := range base {
		result[key] = value
	}
	for key, value := range additions {
		if existing, ok := result[key]; ok && existing != value {
			return nil, fmt.Errorf(
				"service environment %q would overwrite prepared subject state",
				key,
			)
		}
		result[key] = value
	}
	return result, nil
}

func runnerImplementation(value Runner) string {
	type implementationReporter interface {
		Implementation() string
	}
	if reporter, ok := value.(implementationReporter); ok {
		if implementation := reporter.Implementation(); implementation != "" {
			return implementation
		}
	}
	return "ruby-reference"
}
