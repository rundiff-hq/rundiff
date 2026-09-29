package boxd

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

type fakeSDKBridgeRunner struct {
	requests  []sdkBridgeRequest
	responses []sdkBridgeResponse
	errs      []error
}

func (runner *fakeSDKBridgeRunner) Run(
	_ context.Context,
	request sdkBridgeRequest,
) (sdkBridgeResponse, error) {
	runner.requests = append(runner.requests, request)
	index := len(runner.requests) - 1

	var response sdkBridgeResponse
	if index < len(runner.responses) {
		response = runner.responses[index]
	}
	var err error
	if index < len(runner.errs) {
		err = runner.errs[index]
	}

	return response, err
}

func TestSDKCreateUsesStructuredBridgeRequest(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		responses: []sdkBridgeResponse{{
			Machine: &sdkBridgeMachine{Name: "rundiff-proof-parent"},
		}},
	}
	client := &SDK{runner: runner}

	machine, err := client.Create(
		context.Background(),
		"rundiff-proof-parent",
		true,
	)
	if err != nil {
		t.Fatalf("Create returned error: %v", err)
	}
	if machine.Name != "rundiff-proof-parent" {
		t.Fatalf("machine name = %q, want rundiff-proof-parent", machine.Name)
	}

	want := sdkBridgeRequest{
		Operation: "create",
		Name:      "rundiff-proof-parent",
		Isolated:  true,
	}
	if !reflect.DeepEqual(runner.requests[0], want) {
		t.Fatalf("request = %#v, want %#v", runner.requests[0], want)
	}
}

func TestSDKForkUsesNamesWithoutShellEncoding(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		responses: []sdkBridgeResponse{{
			Machine: &sdkBridgeMachine{Name: "execution-base"},
		}},
	}
	client := &SDK{runner: runner}

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

	want := sdkBridgeRequest{
		Operation: "fork",
		Source:    "rundiff-golden-v1",
		Name:      "execution-base",
	}
	if !reflect.DeepEqual(runner.requests[0], want) {
		t.Fatalf("request = %#v, want %#v", runner.requests[0], want)
	}
}

func TestSDKExecPreservesRemoteExitCodeAsWorkloadResult(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		responses: []sdkBridgeResponse{{
			Stdout:   "scenario output",
			Stderr:   "scenario failed",
			ExitCode: 17,
		}},
	}
	client := &SDK{runner: runner}

	argv := []string{"ruby", "script/run.rb", "--role", "candidate"}
	result, err := client.Exec(
		context.Background(),
		compute.Machine{Name: "execution-candidate"},
		argv,
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

	want := sdkBridgeRequest{
		Operation: "exec",
		Machine:   "execution-candidate",
		Argv:      argv,
	}
	if !reflect.DeepEqual(runner.requests[0], want) {
		t.Fatalf("request = %#v, want %#v", runner.requests[0], want)
	}
}

func TestSDKExecRejectsEmptyArgv(t *testing.T) {
	client := &SDK{runner: &fakeSDKBridgeRunner{}}

	_, err := client.Exec(
		context.Background(),
		compute.Machine{Name: "execution-candidate"},
		nil,
	)
	if err == nil {
		t.Fatal("expected empty argv error")
	}
}

func TestSDKTransportFailureRemainsProviderError(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		errs: []error{errors.New("authentication failed")},
	}
	client := &SDK{runner: runner}

	_, err := client.Exec(
		context.Background(),
		compute.Machine{Name: "execution-base"},
		[]string{"true"},
	)
	if err == nil {
		t.Fatal("expected provider error")
	}
}

func TestSDKRemoveUsesStructuredBridgeRequest(t *testing.T) {
	runner := &fakeSDKBridgeRunner{}
	client := &SDK{runner: runner}

	err := client.Remove(
		context.Background(),
		compute.Machine{Name: "execution-candidate"},
	)
	if err != nil {
		t.Fatalf("Remove returned error: %v", err)
	}

	want := sdkBridgeRequest{
		Operation: "remove",
		Machine:   "execution-candidate",
	}
	if !reflect.DeepEqual(runner.requests[0], want) {
		t.Fatalf("request = %#v, want %#v", runner.requests[0], want)
	}
}

func TestSDKRejectsBridgeMachineNameMismatch(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		responses: []sdkBridgeResponse{{
			Machine: &sdkBridgeMachine{Name: "wrong-name"},
		}},
	}
	client := &SDK{runner: runner}

	_, err := client.Create(context.Background(), "expected-name", true)
	if err == nil {
		t.Fatal("expected bridge machine name mismatch error")
	}
}


func TestSDKGetReturnsMachineByName(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		responses: []sdkBridgeResponse{{
			Machine: &sdkBridgeMachine{Name: "rundiff-golden-abc"},
		}},
	}
	client := &SDK{runner: runner}

	machine, err := client.Get(context.Background(), "rundiff-golden-abc")
	if err != nil {
		t.Fatalf("Get returned error: %v", err)
	}
	if machine.Name != "rundiff-golden-abc" {
		t.Fatalf("machine name = %q", machine.Name)
	}

	want := sdkBridgeRequest{
		Operation: "get",
		Name:      "rundiff-golden-abc",
	}
	if !reflect.DeepEqual(runner.requests[0], want) {
		t.Fatalf("request = %#v, want %#v", runner.requests[0], want)
	}
}

func TestSDKGetReturnsTypedNotFound(t *testing.T) {
	runner := &fakeSDKBridgeRunner{
		responses: []sdkBridgeResponse{{NotFound: true}},
	}
	client := &SDK{runner: runner}

	_, err := client.Get(context.Background(), "missing")
	if !errors.Is(err, ErrMachineNotFound) {
		t.Fatalf("Get error = %v, want ErrMachineNotFound", err)
	}
}
