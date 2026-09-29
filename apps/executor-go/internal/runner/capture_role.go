package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/sensor"
)

type CaptureRole string

const (
	CaptureRoleBase      CaptureRole = "base"
	CaptureRoleCandidate CaptureRole = "candidate"
)

func (role CaptureRole) Validate() error {
	switch role {
	case CaptureRoleBase, CaptureRoleCandidate:
		return nil
	default:
		return fmt.Errorf("unsupported capture role %q", role)
	}
}

type CaptureRoleInput struct {
	Role                CaptureRole
	Root                string
	Label               string
	SHA                 string
	ScenarioPath        string
	PreparedEnvironment map[string]string
	OutputPath          string
}

type RoleCapture struct {
	ToolRoot string
	Runner   CaptureCommandRunner
	Stdout   io.Writer
	Stderr   io.Writer
}

func (capture *RoleCapture) Capture(
	ctx context.Context,
	request protocol.RequestV1,
	input CaptureRoleInput,
) (json.RawMessage, error) {
	if err := input.Role.Validate(); err != nil {
		return nil, err
	}
	if input.Root == "" {
		return nil, errors.New("capture root is required")
	}
	if input.SHA == "" {
		return nil, errors.New("capture SHA is required")
	}
	if input.OutputPath == "" {
		return nil, errors.New("capture output path is required")
	}

	spec, err := sensor.NewRegistry(capture.ToolRoot).Resolve(input.Root)
	if err != nil {
		return nil, fmt.Errorf("resolve %s sensor: %w", input.Role, err)
	}

	label := input.Label
	if label == "" {
		label = input.SHA
	}

	env := cloneCaptureEnvironment(input.PreparedEnvironment)
	env["RUNDIFF_RUN_ID"] = request.ExecutionID
	env["RUNDIFF_SCENARIO_ID"] = request.ScenarioID
	env["RUNDIFF_SUBJECT"] = "github-pull-request"
	env["RUNDIFF_EXECUTION_LABEL"] = label
	env["RUNDIFF_EXECUTION_SHA"] = input.SHA
	env["RUNDIFF_OUTPUT"] = input.OutputPath
	env["RUNDIFF_CAPTURE_RUNTIME"] = spec.Mode
	env["RUNDIFF_SENSOR_SCHEMA_VERSION"] = sensor.SchemaVersion
	env["RUNDIFF_SENSOR_ADAPTER"] = spec.Adapter
	env["RUNDIFF_SENSOR_RUNTIME"] = spec.Runtime
	env["RUNDIFF_SCENARIO_PATH"] = input.ScenarioPath
	if spec.TargetURLEnv != "" {
		baseURL := input.PreparedEnvironment[spec.TargetURLEnv]
		if baseURL == "" {
			return nil, fmt.Errorf(
				"capture %s requires service URL environment %s",
				input.Role,
				spec.TargetURLEnv,
			)
		}
		env["RUNDIFF_SCENARIO_BASE_URL"] = baseURL
	}

	if err := capture.commandRunner().Run(ctx, CaptureCommand{
		Dir:     input.Root,
		Command: spec.Command,
		Env:     env,
		Stdout:  capture.Stdout,
		Stderr:  capture.Stderr,
	}); err != nil {
		return nil, fmt.Errorf("capture %s: %w", input.Role, err)
	}

	body, err := os.ReadFile(input.OutputPath)
	if err != nil {
		return nil, fmt.Errorf("capture %s output: %w", input.Role, err)
	}
	if !json.Valid(body) {
		return nil, fmt.Errorf("capture %s output is invalid JSON", input.Role)
	}
	if err := sensor.ValidateCapture(body, sensor.ExpectedCapture{
		RunID:      request.ExecutionID,
		ScenarioID: request.ScenarioID,
		Subject:    "github-pull-request",
		Label:      label,
		SHA:        input.SHA,
		Spec:       spec,
	}); err != nil {
		return nil, fmt.Errorf("capture %s contract: %w", input.Role, err)
	}

	return json.RawMessage(append([]byte(nil), body...)), nil
}

func (capture *RoleCapture) commandRunner() CaptureCommandRunner {
	if capture.Runner != nil {
		return capture.Runner
	}
	return OSCaptureCommandRunner{}
}
