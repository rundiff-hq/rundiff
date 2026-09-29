package boxd

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

type fakeCall struct {
	binary string
	args   []string
}

type fakeRunner struct {
	calls   []fakeCall
	results []commandResult
	errs    []error
}

func (runner *fakeRunner) Run(
	_ context.Context,
	binary string,
	args ...string,
) (commandResult, error) {
	runner.calls = append(
		runner.calls,
		fakeCall{
			binary: binary,
			args:   append([]string(nil), args...),
		},
	)

	index := len(runner.calls) - 1
	var result commandResult
	if index < len(runner.results) {
		result = runner.results[index]
	}
	var err error
	if index < len(runner.errs) {
		err = runner.errs[index]
	}
	return result, err
}

func TestForkUsesDocumentedArgvWithoutShell(t *testing.T) {
	runner := &fakeRunner{
		results: []commandResult{{exitCode: 0}},
	}
	client := &CLI{
		binary: "boxd",
		runner: runner,
	}

	machine, err := client.Fork(
		context.Background(),
		"rundiff-golden-v1",
		"execution-base",
	)
	if err != nil {
		t.Fatalf("Fork returned error: %v", err)
	}
	if machine.Name != "execution-base" {
		t.Fatalf("machine name = %q, want execution-base", machine.Name)
	}

	want := fakeCall{
		binary: "boxd",
		args: []string{
			"machine",
			"fork",
			"rundiff-golden-v1",
			"execution-base",
			"--json",
		},
	}
	if !reflect.DeepEqual(runner.calls[0], want) {
		t.Fatalf("call = %#v, want %#v", runner.calls[0], want)
	}
}

func TestExecPreservesRemoteExitCodeAsWorkloadResult(t *testing.T) {
	runner := &fakeRunner{
		results: []commandResult{{
			stdout:   "scenario output",
			stderr:   "scenario failed",
			exitCode: 17,
		}},
	}
	client := &CLI{
		binary: "boxd",
		runner: runner,
	}

	result, err := client.Exec(
		context.Background(),
		compute.Machine{Name: "execution-candidate"},
		[]string{"ruby", "script/run.rb", "--role", "candidate"},
	)
	if err != nil {
		t.Fatalf("Exec returned provider error for workload exit: %v", err)
	}
	if result.ExitCode != 17 {
		t.Fatalf("exit code = %d, want 17", result.ExitCode)
	}
	if result.Stdout != "scenario output" || result.Stderr != "scenario failed" {
		t.Fatalf("unexpected output: %#v", result)
	}

	wantArgs := []string{
		"machine",
		"exec",
		"execution-candidate",
		"--",
		"ruby",
		"script/run.rb",
		"--role",
		"candidate",
	}
	if !reflect.DeepEqual(runner.calls[0].args, wantArgs) {
		t.Fatalf("args = %#v, want %#v", runner.calls[0].args, wantArgs)
	}
}

func TestExecRejectsEmptyArgv(t *testing.T) {
	client := &CLI{
		binary: "boxd",
		runner: &fakeRunner{},
	}

	_, err := client.Exec(
		context.Background(),
		compute.Machine{Name: "execution-candidate"},
		nil,
	)
	if err == nil {
		t.Fatal("expected empty argv error")
	}
}

func TestForkReturnsProviderErrorForLifecycleExit(t *testing.T) {
	runner := &fakeRunner{
		results: []commandResult{{exitCode: 9}},
	}
	client := &CLI{
		binary: "boxd",
		runner: runner,
	}

	_, err := client.Fork(
		context.Background(),
		"golden",
		"candidate",
	)
	if err == nil {
		t.Fatal("expected provider error")
	}
}

func TestRemoveUsesNonInteractiveLifecycleCommand(t *testing.T) {
	runner := &fakeRunner{
		results: []commandResult{{exitCode: 0}},
	}
	client := &CLI{
		binary: "boxd",
		runner: runner,
	}

	err := client.Remove(
		context.Background(),
		compute.Machine{Name: "execution-candidate"},
	)
	if err != nil {
		t.Fatalf("Remove returned error: %v", err)
	}

	wantArgs := []string{
		"machine",
		"remove",
		"execution-candidate",
		"-y",
		"--json",
	}
	if !reflect.DeepEqual(runner.calls[0].args, wantArgs) {
		t.Fatalf("args = %#v, want %#v", runner.calls[0].args, wantArgs)
	}
}

func TestTransportFailureRemainsProviderError(t *testing.T) {
	runner := &fakeRunner{
		errs: []error{errors.New("binary unavailable")},
	}
	client := &CLI{
		binary: "boxd",
		runner: runner,
	}

	_, err := client.Exec(
		context.Background(),
		compute.Machine{Name: "execution-base"},
		[]string{"true"},
	)
	if err == nil {
		t.Fatal("expected transport error")
	}
}
