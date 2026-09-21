package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/workspace"
)

type Process struct {
	Command []string
	Dir     string
	Env     []string
	Stdout  io.Writer
	Stderr  io.Writer
}

func (r Process) Run(
	ctx context.Context,
	request protocol.RequestV1,
	prepared workspace.Prepared,
	recorder journal.Recorder,
) (protocol.ResultV1, error) {
	if len(r.Command) == 0 {
		return protocol.ResultV1{}, fmt.Errorf("reference process command is required")
	}

	workspace, err := os.MkdirTemp("", "rundiff-go-executor-*")
	if err != nil {
		return protocol.ResultV1{}, err
	}
	if err := recorder.Append(resourceEntry(request, "resource_created", "workspace", workspace)); err != nil {
		os.RemoveAll(workspace)
		return protocol.ResultV1{}, err
	}
	defer func() {
		_ = os.RemoveAll(workspace)
		_ = recorder.Append(resourceEntry(request, "resource_removed", "workspace", workspace))
	}()

	requestPath := filepath.Join(workspace, "request.json")
	resultPath := filepath.Join(workspace, "result.json")
	if err := protocol.WriteRequest(requestPath, request); err != nil {
		return protocol.ResultV1{}, err
	}

	command := exec.CommandContext(ctx, r.Command[0], r.Command[1:]...)
	command.Dir = r.Dir
	command.Env = os.Environ()
	command.Env = setEnv(command.Env, "RUNDIFF_EXECUTOR_REQUEST_PATH", requestPath)
	command.Env = setEnv(command.Env, "RUNDIFF_EXECUTOR_RESULT_PATH", resultPath)
	for _, item := range r.Env {
		command.Env = setRawEnv(command.Env, item)
	}
	for _, item := range prepared.Environment {
		command.Env = setRawEnv(command.Env, item)
	}
	if prepared.BaselineEnvironment != nil {
		body, marshalErr := json.Marshal(prepared.BaselineEnvironment)
		if marshalErr != nil {
			return protocol.ResultV1{}, marshalErr
		}
		command.Env = setEnv(
			command.Env,
			"RUNDIFF_PREPARED_BASELINE_RUNTIME_ENV_JSON",
			string(body),
		)
	}
	if prepared.CandidateEnvironment != nil {
		body, marshalErr := json.Marshal(prepared.CandidateEnvironment)
		if marshalErr != nil {
			return protocol.ResultV1{}, marshalErr
		}
		command.Env = setEnv(
			command.Env,
			"RUNDIFF_PREPARED_CANDIDATE_RUNTIME_ENV_JSON",
			string(body),
		)
	}
	command.Stdout = r.Stdout
	command.Stderr = r.Stderr

	if err := command.Start(); err != nil {
		return protocol.Failed("RunDiff::Executor::ReferenceProcessStartError", err.Error()), nil
	}
	_ = recorder.Append(resourceEntry(request, "resource_created", "process", strconv.Itoa(command.Process.Pid)))

	waitErr := command.Wait()
	_ = recorder.Append(resourceEntry(request, "resource_removed", "process", strconv.Itoa(command.Process.Pid)))

	if ctx.Err() != nil {
		return protocol.Failed("RunDiff::Executor::Cancelled", ctx.Err().Error()), nil
	}
	if waitErr != nil {
		return protocol.Failed("RunDiff::Executor::ReferenceProcessError", waitErr.Error()), nil
	}

	result, err := protocol.LoadResult(resultPath)
	if err != nil {
		return protocol.Failed("RunDiff::Executor::ReferenceResultError", err.Error()), nil
	}
	return result, nil
}

func resourceEntry(request protocol.RequestV1, kind, resourceKind, resource string) journal.Entry {
	return journal.Entry{
		Kind:          kind,
		ExecutionID:   request.ExecutionID,
		AttemptNumber: request.AttemptNumber,
		ResourceKind:  resourceKind,
		Resource:      resource,
	}
}

func setEnv(environment []string, key, value string) []string {
	return setRawEnv(environment, key+"="+value)
}

func setRawEnv(environment []string, item string) []string {
	key := item
	if index := indexByte(item, '='); index >= 0 {
		key = item[:index]
	}

	prefix := key + "="
	for index, existing := range environment {
		if len(existing) >= len(prefix) && existing[:len(prefix)] == prefix {
			environment[index] = item
			return environment
		}
	}
	return append(environment, item)
}

func indexByte(value string, target byte) int {
	for index := 0; index < len(value); index++ {
		if value[index] == target {
			return index
		}
	}
	return -1
}
