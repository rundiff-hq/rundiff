package boxd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

type sdkBridgeRequest struct {
	Operation string   `json:"operation"`
	Name      string   `json:"name,omitempty"`
	Source    string   `json:"source,omitempty"`
	Machine   string   `json:"machine,omitempty"`
	Isolated  bool     `json:"isolated,omitempty"`
	Argv      []string `json:"argv,omitempty"`
}

type sdkBridgeMachine struct {
	Name string `json:"name"`
}

type sdkBridgeResponse struct {
	Machine  *sdkBridgeMachine `json:"machine,omitempty"`
	Stdout   string            `json:"stdout,omitempty"`
	Stderr   string            `json:"stderr,omitempty"`
	ExitCode int               `json:"exitCode,omitempty"`
}

type sdkBridgeRunner interface {
	Run(context.Context, sdkBridgeRequest) (sdkBridgeResponse, error)
}

type nodeSDKBridgeRunner struct {
	binary string
	script string
}

func (runner nodeSDKBridgeRunner) Run(
	ctx context.Context,
	request sdkBridgeRequest,
) (sdkBridgeResponse, error) {
	payload, err := json.Marshal(request)
	if err != nil {
		return sdkBridgeResponse{}, fmt.Errorf("encode boxd sdk bridge request: %w", err)
	}

	command := exec.CommandContext(ctx, runner.binary, runner.script)
	command.Stdin = bytes.NewReader(payload)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return sdkBridgeResponse{}, ctx.Err()
		}

		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return sdkBridgeResponse{}, fmt.Errorf(
				"boxd sdk bridge exited with code %d: %s",
				exitErr.ExitCode(),
				strings.TrimSpace(stderr.String()),
			)
		}

		return sdkBridgeResponse{}, fmt.Errorf("run boxd sdk bridge: %w", err)
	}

	var response sdkBridgeResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		return sdkBridgeResponse{}, fmt.Errorf(
			"decode boxd sdk bridge response: %w",
			err,
		)
	}

	return response, nil
}

type SDK struct {
	runner sdkBridgeRunner
}

func NewSDK(nodeBinary, scriptPath string) *SDK {
	if nodeBinary == "" {
		nodeBinary = "node"
	}
	if scriptPath == "" {
		scriptPath = "sdkbridge/bridge.mjs"
	}
	return &SDK{
		runner: nodeSDKBridgeRunner{
			binary: nodeBinary,
			script: scriptPath,
		},
	}
}

func (client *SDK) Create(
	ctx context.Context,
	name string,
	isolated bool,
) (compute.Machine, error) {
	if name == "" {
		return compute.Machine{}, errors.New("boxd machine name is required")
	}

	response, err := client.runner.Run(
		ctx,
		sdkBridgeRequest{
			Operation: "create",
			Name:      name,
			Isolated:  isolated,
		},
	)
	if err != nil {
		return compute.Machine{}, fmt.Errorf("boxd sdk create %q: %w", name, err)
	}

	return machineFromBridge(response, name)
}

func (client *SDK) Fork(
	ctx context.Context,
	sourceName string,
	childName string,
) (compute.Machine, error) {
	if sourceName == "" || childName == "" {
		return compute.Machine{}, errors.New("boxd fork source and child names are required")
	}

	response, err := client.runner.Run(
		ctx,
		sdkBridgeRequest{
			Operation: "fork",
			Source:    sourceName,
			Name:      childName,
		},
	)
	if err != nil {
		return compute.Machine{}, fmt.Errorf(
			"boxd sdk fork %q -> %q: %w",
			sourceName,
			childName,
			err,
		)
	}

	return machineFromBridge(response, childName)
}

func (client *SDK) Exec(
	ctx context.Context,
	machine compute.Machine,
	argv []string,
) (compute.ExecResult, error) {
	if machine.Name == "" {
		return compute.ExecResult{}, errors.New("boxd exec machine name is required")
	}
	if len(argv) == 0 {
		return compute.ExecResult{}, errors.New("boxd exec requires argv")
	}

	response, err := client.runner.Run(
		ctx,
		sdkBridgeRequest{
			Operation: "exec",
			Machine:   machine.Name,
			Argv:      append([]string(nil), argv...),
		},
	)
	if err != nil {
		return compute.ExecResult{}, fmt.Errorf(
			"boxd sdk exec %q: %w",
			machine.Name,
			err,
		)
	}

	return compute.ExecResult{
		Stdout:   response.Stdout,
		Stderr:   response.Stderr,
		ExitCode: response.ExitCode,
	}, nil
}

func (client *SDK) Remove(
	ctx context.Context,
	machine compute.Machine,
) error {
	if machine.Name == "" {
		return errors.New("boxd remove machine name is required")
	}

	_, err := client.runner.Run(
		ctx,
		sdkBridgeRequest{
			Operation: "remove",
			Machine:   machine.Name,
		},
	)
	if err != nil {
		return fmt.Errorf("boxd sdk remove %q: %w", machine.Name, err)
	}
	return nil
}

func machineFromBridge(
	response sdkBridgeResponse,
	expectedName string,
) (compute.Machine, error) {
	if response.Machine == nil || response.Machine.Name == "" {
		return compute.Machine{}, errors.New("boxd sdk bridge returned no machine")
	}
	if response.Machine.Name != expectedName {
		return compute.Machine{}, fmt.Errorf(
			"boxd sdk bridge returned machine %q, want %q",
			response.Machine.Name,
			expectedName,
		)
	}

	return compute.Machine{Name: response.Machine.Name}, nil
}
