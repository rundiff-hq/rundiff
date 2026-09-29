package compute

import (
	"context"
	"errors"
)

type Machine struct {
	Name string
}

type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

type Provider interface {
	Fork(ctx context.Context, sourceName, childName string) (Machine, error)
	Exec(ctx context.Context, machine Machine, argv []string) (ExecResult, error)
	Remove(ctx context.Context, machine Machine) error
}

type Pair struct {
	Baseline  Machine
	Candidate Machine
}

type PairForker interface {
	ForkPair(
		ctx context.Context,
		sourceName string,
		baselineName string,
		candidateName string,
	) (Pair, error)
}

func ForkPair(
	ctx context.Context,
	provider Provider,
	sourceName string,
	baselineName string,
	candidateName string,
) (Pair, error) {
	if pairForker, ok := provider.(PairForker); ok {
		return pairForker.ForkPair(
			ctx,
			sourceName,
			baselineName,
			candidateName,
		)
	}

	baseline, err := provider.Fork(ctx, sourceName, baselineName)
	if err != nil {
		return Pair{}, err
	}

	candidate, err := provider.Fork(ctx, sourceName, candidateName)
	if err != nil {
		cleanupErr := provider.Remove(ctx, baseline)
		return Pair{}, errors.Join(err, cleanupErr)
	}

	return Pair{
		Baseline:  baseline,
		Candidate: candidate,
	}, nil
}

func (pair Pair) Cleanup(ctx context.Context, provider Provider) error {
	candidateErr := provider.Remove(ctx, pair.Candidate)
	baselineErr := provider.Remove(ctx, pair.Baseline)
	return errors.Join(candidateErr, baselineErr)
}
