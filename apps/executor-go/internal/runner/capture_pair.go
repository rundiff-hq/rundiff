package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/comparison"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/sensor"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/serviceplan"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/workspace"
)

type CaptureCommand struct {
	Dir     string
	Command []string
	Env     map[string]string
	Stdout  io.Writer
	Stderr  io.Writer
}

type CaptureCommandRunner interface {
	Run(context.Context, CaptureCommand) error
}

type OSCaptureCommandRunner struct{}

func (OSCaptureCommandRunner) Run(
	ctx context.Context,
	spec CaptureCommand,
) error {
	if len(spec.Command) == 0 {
		return errors.New("capture command is required")
	}
	command := exec.CommandContext(ctx, spec.Command[0], spec.Command[1:]...)
	command.Dir = spec.Dir
	command.Env = safeCaptureEnvironment(spec.Env)
	command.Stdout = spec.Stdout
	command.Stderr = spec.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s: %w", strings.Join(spec.Command, " "), err)
	}
	return nil
}

type CapturePair struct {
	ToolRoot string
	Runner   CaptureCommandRunner
	Stdout   io.Writer
	Stderr   io.Writer
}

func (r *CapturePair) Implementation() string {
	return "go-orchestrator"
}

func NewCapturePair(toolRoot string, stdout, stderr io.Writer) *CapturePair {
	return &CapturePair{
		ToolRoot: toolRoot,
		Runner:   OSCaptureCommandRunner{},
		Stdout:   stdout,
		Stderr:   stderr,
	}
}

func (r *CapturePair) Run(
	ctx context.Context,
	request protocol.RequestV1,
	prepared workspace.Prepared,
	recorder journal.Recorder,
) (protocol.ResultV1, error) {
	if prepared.BaselineRoot == "" || prepared.CandidateRoot == "" {
		return protocol.ResultV1{}, errors.New("native capture requires prepared baseline and candidate worktrees")
	}
	scenarioPath, err := serviceplan.ScenarioPath(prepared.CandidateRoot)
	if err != nil {
		return protocol.ResultV1{}, err
	}

	outputRoot, err := os.MkdirTemp(prepared.Root, "capture-")
	if err != nil {
		return protocol.ResultV1{}, err
	}
	if err := recorder.Append(resourceEntry(
		request,
		"resource_created",
		"capture_workspace",
		outputRoot,
	)); err != nil {
		_ = os.RemoveAll(outputRoot)
		return protocol.ResultV1{}, err
	}
	defer func() {
		_ = os.RemoveAll(outputRoot)
		_ = recorder.Append(resourceEntry(
			request,
			"resource_removed",
			"capture_workspace",
			outputRoot,
		))
	}()

	basePath := filepath.Join(outputRoot, "base.json")
	candidatePath := filepath.Join(outputRoot, "candidate.json")

	if err := r.capture(
		ctx,
		request,
		"base",
		prepared.BaselineRoot,
		request.Context.BaselineRef,
		request.BaselineSHA,
		scenarioPath,
		prepared.BaselineSubjectEnvironment,
		basePath,
	); err != nil {
		return protocol.ResultV1{}, err
	}
	if err := r.capture(
		ctx,
		request,
		"candidate",
		prepared.CandidateRoot,
		request.Context.CandidateRef,
		request.CandidateSHA,
		scenarioPath,
		prepared.CandidateSubjectEnvironment,
		candidatePath,
	); err != nil {
		return protocol.ResultV1{}, err
	}

	changedPaths, err := r.changedPaths(ctx, request, prepared.RepositoryRoot)
	if err != nil {
		return protocol.ResultV1{}, err
	}
	payload, err := comparison.CompareFiles(
		basePath,
		candidatePath,
		changedPaths,
	)
	if err != nil {
		return protocol.ResultV1{}, fmt.Errorf(
			"compare captures: %w",
			err,
		)
	}
	return protocol.ResultV1{
		SchemaVersion: protocol.SchemaVersion,
		Status:        "succeeded",
		Payload:       payload,
	}, nil
}

func (r *CapturePair) capture(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	label string,
	sha string,
	scenarioPath string,
	preparedEnv map[string]string,
	output string,
) error {
	spec, err := sensor.NewRegistry(r.ToolRoot).Resolve(root)
	if err != nil {
		return fmt.Errorf("resolve %s sensor: %w", role, err)
	}
	if label == "" {
		label = sha
	}
	env := cloneCaptureEnvironment(preparedEnv)
	env["RUNDIFF_RUN_ID"] = request.ExecutionID
	env["RUNDIFF_SCENARIO_ID"] = request.ScenarioID
	env["RUNDIFF_SUBJECT"] = "github-pull-request"
	env["RUNDIFF_EXECUTION_LABEL"] = label
	env["RUNDIFF_EXECUTION_SHA"] = sha
	env["RUNDIFF_OUTPUT"] = output
	env["RUNDIFF_CAPTURE_RUNTIME"] = spec.Mode
	env["RUNDIFF_SENSOR_SCHEMA_VERSION"] = sensor.SchemaVersion
	env["RUNDIFF_SENSOR_ADAPTER"] = spec.Adapter
	env["RUNDIFF_SENSOR_RUNTIME"] = spec.Runtime
	env["RUNDIFF_SCENARIO_PATH"] = scenarioPath
	if spec.TargetURLEnv != "" {
		baseURL := preparedEnv[spec.TargetURLEnv]
		if baseURL == "" {
			return fmt.Errorf("capture %s requires service URL environment %s", role, spec.TargetURLEnv)
		}
		env["RUNDIFF_SCENARIO_BASE_URL"] = baseURL
	}

	if err := r.commandRunner().Run(ctx, CaptureCommand{
		Dir:     root,
		Command: spec.Command,
		Env:     env,
		Stdout:  r.Stdout,
		Stderr:  r.Stderr,
	}); err != nil {
		return fmt.Errorf("capture %s: %w", role, err)
	}
	body, err := os.ReadFile(output)
	if err != nil {
		return fmt.Errorf("capture %s output: %w", role, err)
	}
	if !json.Valid(body) {
		return fmt.Errorf("capture %s output is invalid JSON", role)
	}
	if err := sensor.ValidateCapture(body, sensor.ExpectedCapture{
		RunID:      request.ExecutionID,
		ScenarioID: request.ScenarioID,
		Subject:    "github-pull-request",
		Label:      label,
		SHA:        sha,
		Spec:       spec,
	}); err != nil {
		return fmt.Errorf("capture %s contract: %w", role, err)
	}
	return nil
}

func (r *CapturePair) changedPaths(
	ctx context.Context,
	request protocol.RequestV1,
	repositoryRoot string,
) ([]string, error) {
	command := exec.CommandContext(
		ctx,
		"git",
		"diff",
		"--name-only",
		request.BaselineSHA+"..."+request.CandidateSHA,
	)
	command.Dir = repositoryRoot
	command.Env = safeCaptureEnvironment(nil)
	output, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("git diff changed paths: %w", err)
	}
	var result []string
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			result = append(result, line)
		}
	}
	return result, nil
}

func (r *CapturePair) commandRunner() CaptureCommandRunner {
	if r.Runner != nil {
		return r.Runner
	}
	return OSCaptureCommandRunner{}
}

func cloneCaptureEnvironment(source map[string]string) map[string]string {
	result := make(map[string]string, len(source)+8)
	for key, value := range source {
		result[key] = value
	}
	return result
}

func safeCaptureEnvironment(explicit map[string]string) []string {
	keys := []string{
		"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
		"SSL_CERT_FILE", "SSL_CERT_DIR",
	}
	environment := make([]string, 0, len(keys)+len(explicit))
	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	explicitKeys := make([]string, 0, len(explicit))
	for key := range explicit {
		explicitKeys = append(explicitKeys, key)
	}
	sort.Strings(explicitKeys)
	for _, key := range explicitKeys {
		environment = append(environment, key+"="+explicit[key])
	}
	return environment
}
