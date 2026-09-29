package boxd

import (
	"context"
	"errors"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

type pairSDKClient interface {
	Create(context.Context, string, bool) (compute.Machine, error)
	Get(context.Context, string) (compute.Machine, error)
	Fork(context.Context, string, string) (compute.Machine, error)
	Exec(context.Context, compute.Machine, []string) (compute.ExecResult, error)
	Remove(context.Context, compute.Machine) error
	Close() error
}

type machineRemover interface {
	Remove(context.Context, compute.Machine) error
}

type PairSDK struct {
	primary        pairSDKClient
	secondary      pairSDKClient
	cleanupFactory func() machineRemover
}

func NewSessionPairSDK(
	nodeBinary string,
	sessionScriptPath string,
	oneShotScriptPath string,
) (*PairSDK, error) {
	primary, err := NewSessionSDK(nodeBinary, sessionScriptPath)
	if err != nil {
		return nil, err
	}

	secondary, err := NewSessionSDK(nodeBinary, sessionScriptPath)
	if err != nil {
		_ = primary.Close()
		return nil, err
	}

	if nodeBinary == "" {
		nodeBinary = "node"
	}
	if oneShotScriptPath == "" {
		oneShotScriptPath = "sdkbridge/bridge.mjs"
	}

	return &PairSDK{
		primary:   primary,
		secondary: secondary,
		cleanupFactory: func() machineRemover {
			return NewSDK(nodeBinary, oneShotScriptPath)
		},
	}, nil
}

func (client *PairSDK) Create(
	ctx context.Context,
	name string,
	isolated bool,
) (compute.Machine, error) {
	return client.primary.Create(ctx, name, isolated)
}

func (client *PairSDK) Get(
	ctx context.Context,
	name string,
) (compute.Machine, error) {
	return client.primary.Get(ctx, name)
}

func (client *PairSDK) Fork(
	ctx context.Context,
	sourceName string,
	childName string,
) (compute.Machine, error) {
	return client.primary.Fork(ctx, sourceName, childName)
}

func (client *PairSDK) Exec(
	ctx context.Context,
	machine compute.Machine,
	argv []string,
) (compute.ExecResult, error) {
	return client.primary.Exec(ctx, machine, argv)
}

func (client *PairSDK) Remove(
	ctx context.Context,
	machine compute.Machine,
) error {
	return client.primary.Remove(ctx, machine)
}

func (client *PairSDK) Close() error {
	if client == nil {
		return nil
	}

	var primaryErr error
	if client.primary != nil {
		primaryErr = client.primary.Close()
	}
	var secondaryErr error
	if client.secondary != nil {
		secondaryErr = client.secondary.Close()
	}
	return errors.Join(primaryErr, secondaryErr)
}

func (client *PairSDK) ForkPair(
	ctx context.Context,
	sourceName string,
	baselineName string,
	candidateName string,
) (compute.Pair, error) {
	if sourceName == "" || baselineName == "" || candidateName == "" {
		return compute.Pair{}, errors.New(
			"boxd pair fork source and child names are required",
		)
	}
	if client.primary == nil || client.secondary == nil {
		return compute.Pair{}, errors.New("boxd pair fork sessions are required")
	}

	type forkResult struct {
		role    string
		machine compute.Machine
		err     error
	}
	results := make(chan forkResult, 2)

	go func() {
		machine, err := client.primary.Fork(ctx, sourceName, baselineName)
		results <- forkResult{role: "baseline", machine: machine, err: err}
	}()
	go func() {
		machine, err := client.secondary.Fork(ctx, sourceName, candidateName)
		results <- forkResult{role: "candidate", machine: machine, err: err}
	}()

	var baseline compute.Machine
	var candidate compute.Machine
	var baselineErr error
	var candidateErr error

	for range 2 {
		result := <-results
		switch result.role {
		case "baseline":
			baseline = result.machine
			baselineErr = result.err
		case "candidate":
			candidate = result.machine
			candidateErr = result.err
		}
	}

	if baselineErr == nil && candidateErr == nil {
		return compute.Pair{
			Baseline:  baseline,
			Candidate: candidate,
		}, nil
	}

	cleanupErr := client.cleanupPairNames(baselineName, candidateName)
	return compute.Pair{}, errors.Join(baselineErr, candidateErr, cleanupErr)
}

func (client *PairSDK) cleanupPairNames(
	baselineName string,
	candidateName string,
) error {
	if client.cleanupFactory == nil {
		return errors.New("boxd pair cleanup provider is required")
	}

	remover := client.cleanupFactory()
	if remover == nil {
		return errors.New("boxd pair cleanup provider is nil")
	}
	if closer, ok := remover.(interface{ Close() error }); ok {
		defer closer.Close()
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	baselineErr := remover.Remove(
		ctx,
		compute.Machine{Name: baselineName},
	)
	candidateErr := remover.Remove(
		ctx,
		compute.Machine{Name: candidateName},
	)
	return errors.Join(baselineErr, candidateErr)
}
