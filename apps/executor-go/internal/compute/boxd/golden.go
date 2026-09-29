package boxd

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute/golden"
)

const defaultGoldenMarkerRoot = "/tmp/rundiff/golden"

type goldenProvider interface {
	Get(context.Context, string) (compute.Machine, error)
	Create(context.Context, string, bool) (compute.Machine, error)
	Exec(context.Context, compute.Machine, []string) (compute.ExecResult, error)
	Remove(context.Context, compute.Machine) error
}

type GoldenEnvironment struct {
	Machine     compute.Machine
	Fingerprint string
	Reused      bool
}

type GoldenManager struct {
	Provider   goldenProvider
	MarkerRoot string
}

type GoldenPrepareFunc func(context.Context, compute.Machine) error

func (manager GoldenManager) Ensure(
	ctx context.Context,
	spec golden.Spec,
	prepare GoldenPrepareFunc,
) (GoldenEnvironment, error) {
	if manager.Provider == nil {
		return GoldenEnvironment{}, errors.New("golden provider is required")
	}
	if prepare == nil {
		return GoldenEnvironment{}, errors.New("golden prepare function is required")
	}

	fingerprint, err := spec.Fingerprint()
	if err != nil {
		return GoldenEnvironment{}, err
	}
	name := golden.MachineName(fingerprint)

	machine, err := manager.Provider.Get(ctx, name)
	switch {
	case err == nil:
		ready, verifyErr := manager.ready(ctx, machine, fingerprint)
		if verifyErr != nil {
			return GoldenEnvironment{}, fmt.Errorf(
				"verify existing golden %q: %w",
				name,
				verifyErr,
			)
		}
		if ready {
			return GoldenEnvironment{
				Machine:     machine,
				Fingerprint: fingerprint,
				Reused:      true,
			}, nil
		}
		if removeErr := manager.Provider.Remove(ctx, machine); removeErr != nil {
			return GoldenEnvironment{}, fmt.Errorf(
				"remove invalid golden %q: %w",
				name,
				removeErr,
			)
		}
	case errors.Is(err, ErrMachineNotFound):
	default:
		return GoldenEnvironment{}, fmt.Errorf(
			"lookup golden %q: %w",
			name,
			err,
		)
	}

	machine, err = manager.Provider.Create(ctx, name, true)
	if err != nil {
		return GoldenEnvironment{}, fmt.Errorf("create golden %q: %w", name, err)
	}

	keep := false
	defer func() {
		if keep {
			return
		}
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		_ = manager.Provider.Remove(cleanupCtx, machine)
	}()

	if err := prepare(ctx, machine); err != nil {
		return GoldenEnvironment{}, fmt.Errorf("prepare golden %q: %w", name, err)
	}
	if err := manager.markReady(ctx, machine, fingerprint); err != nil {
		return GoldenEnvironment{}, fmt.Errorf("mark golden %q ready: %w", name, err)
	}

	keep = true
	return GoldenEnvironment{
		Machine:     machine,
		Fingerprint: fingerprint,
		Reused:      false,
	}, nil
}

func (manager GoldenManager) ready(
	ctx context.Context,
	machine compute.Machine,
	fingerprint string,
) (bool, error) {
	result, err := manager.Provider.Exec(
		ctx,
		machine,
		[]string{"test", "-f", manager.markerPath(fingerprint)},
	)
	if err != nil {
		return false, err
	}
	return result.ExitCode == 0, nil
}

func (manager GoldenManager) markReady(
	ctx context.Context,
	machine compute.Machine,
	fingerprint string,
) error {
	root := manager.markerRoot()
	if err := manager.execOK(
		ctx,
		machine,
		[]string{"mkdir", "-p", root},
	); err != nil {
		return err
	}
	return manager.execOK(
		ctx,
		machine,
		[]string{"touch", manager.markerPath(fingerprint)},
	)
}

func (manager GoldenManager) execOK(
	ctx context.Context,
	machine compute.Machine,
	argv []string,
) error {
	result, err := manager.Provider.Exec(ctx, machine, argv)
	if err != nil {
		return err
	}
	if result.ExitCode != 0 {
		return fmt.Errorf(
			"remote command exited with code %d: %s",
			result.ExitCode,
			result.Stderr,
		)
	}
	return nil
}

func (manager GoldenManager) markerRoot() string {
	if manager.MarkerRoot != "" {
		return manager.MarkerRoot
	}
	return defaultGoldenMarkerRoot
}

func (manager GoldenManager) markerPath(fingerprint string) string {
	return filepath.Join(manager.markerRoot(), fingerprint+".ready")
}
