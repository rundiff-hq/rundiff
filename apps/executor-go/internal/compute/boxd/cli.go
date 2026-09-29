package boxd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

type commandResult struct {
	stdout   string
	stderr   string
	exitCode int
}

type commandRunner interface {
	Run(ctx context.Context, binary string, args ...string) (commandResult, error)
}

type osCommandRunner struct{}

func (osCommandRunner) Run(
	ctx context.Context,
	binary string,
	args ...string,
) (commandResult, error) {
	command := exec.CommandContext(ctx, binary, args...)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	err := command.Run()
	result := commandResult{
		stdout:   stdout.String(),
		stderr:   stderr.String(),
		exitCode: 0,
	}
	if err == nil {
		return result, nil
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}

	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		result.exitCode = exitErr.ExitCode()
		return result, nil
	}

	return result, err
}

type CLI struct {
	binary string
	runner commandRunner
}

func New(binary string) *CLI {
	if binary == "" {
		binary = "boxd"
	}
	return &CLI{
		binary: binary,
		runner: osCommandRunner{},
	}
}

func (client *CLI) Fork(
	ctx context.Context,
	sourceName string,
	childName string,
) (compute.Machine, error) {
	result, err := client.runner.Run(
		ctx,
		client.binary,
		"machine",
		"fork",
		sourceName,
		childName,
		"--json",
	)
	if err != nil {
		return compute.Machine{}, fmt.Errorf("run boxd fork: %w", err)
	}
	if result.exitCode != 0 {
		return compute.Machine{}, fmt.Errorf(
			"boxd fork %q -> %q exited with code %d",
			sourceName,
			childName,
			result.exitCode,
		)
	}

	return compute.Machine{Name: childName}, nil
}

func (client *CLI) Exec(
	ctx context.Context,
	machine compute.Machine,
	argv []string,
) (compute.ExecResult, error) {
	if len(argv) == 0 {
		return compute.ExecResult{}, errors.New("boxd exec requires argv")
	}

	args := []string{
		"machine",
		"exec",
		machine.Name,
		"--",
	}
	args = append(args, argv...)

	result, err := client.runner.Run(ctx, client.binary, args...)
	if err != nil {
		return compute.ExecResult{}, fmt.Errorf("run boxd exec: %w", err)
	}

	return compute.ExecResult{
		Stdout:   result.stdout,
		Stderr:   result.stderr,
		ExitCode: result.exitCode,
	}, nil
}

func (client *CLI) Remove(
	ctx context.Context,
	machine compute.Machine,
) error {
	result, err := client.runner.Run(
		ctx,
		client.binary,
		"machine",
		"remove",
		machine.Name,
		"-y",
		"--json",
	)
	if err != nil {
		return fmt.Errorf("run boxd remove: %w", err)
	}
	if result.exitCode != 0 {
		return fmt.Errorf(
			"boxd remove %q exited with code %d",
			machine.Name,
			result.exitCode,
		)
	}
	return nil
}
