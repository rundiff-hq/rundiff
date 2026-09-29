package boxd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type sessionBridgeRequest struct {
	ID      uint64           `json:"id"`
	Request sdkBridgeRequest `json:"request"`
}

type sessionBridgeResponse struct {
	ID       uint64             `json:"id"`
	Response *sdkBridgeResponse `json:"response,omitempty"`
	Error    string             `json:"error,omitempty"`
}

type nodeSDKSessionRunner struct {
	mu      sync.Mutex
	command *exec.Cmd
	stdin   io.WriteCloser
	stdout  *bufio.Reader
	stderr  bytes.Buffer
	nextID  uint64
	closed  bool
}

func NewSessionSDK(nodeBinary, scriptPath string) (*SDK, error) {
	if nodeBinary == "" {
		nodeBinary = "node"
	}
	if scriptPath == "" {
		scriptPath = "sdkbridge/session.mjs"
	}

	runner, err := newNodeSDKSessionRunner(nodeBinary, scriptPath)
	if err != nil {
		return nil, err
	}
	return &SDK{runner: runner}, nil
}

func newNodeSDKSessionRunner(
	nodeBinary string,
	scriptPath string,
) (*nodeSDKSessionRunner, error) {
	command := exec.Command(nodeBinary, scriptPath)

	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("boxd sdk session stdin: %w", err)
	}
	stdoutPipe, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("boxd sdk session stdout: %w", err)
	}

	runner := &nodeSDKSessionRunner{
		command: command,
		stdin:   stdin,
		stdout:  bufio.NewReader(stdoutPipe),
	}
	command.Stderr = &runner.stderr

	if err := command.Start(); err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("start boxd sdk session bridge: %w", err)
	}
	return runner, nil
}

func (runner *nodeSDKSessionRunner) Run(
	ctx context.Context,
	request sdkBridgeRequest,
) (sdkBridgeResponse, error) {
	runner.mu.Lock()
	defer runner.mu.Unlock()

	if runner.closed {
		return sdkBridgeResponse{}, errors.New("boxd sdk session is closed")
	}
	select {
	case <-ctx.Done():
		return sdkBridgeResponse{}, ctx.Err()
	default:
	}

	runner.nextID++
	envelope := sessionBridgeRequest{
		ID:      runner.nextID,
		Request: request,
	}
	body, err := json.Marshal(envelope)
	if err != nil {
		return sdkBridgeResponse{}, fmt.Errorf("encode boxd sdk session request: %w", err)
	}
	body = append(body, '\n')
	if _, err := runner.stdin.Write(body); err != nil {
		_ = runner.terminateLocked(true)
		return sdkBridgeResponse{}, fmt.Errorf("write boxd sdk session request: %w", err)
	}

	type readResult struct {
		line string
		err  error
	}
	responseCh := make(chan readResult, 1)
	go func() {
		line, readErr := runner.stdout.ReadString('\n')
		responseCh <- readResult{line: line, err: readErr}
	}()

	var read readResult
	select {
	case <-ctx.Done():
		_ = runner.terminateLocked(true)
		return sdkBridgeResponse{}, ctx.Err()
	case read = <-responseCh:
	}
	if read.err != nil {
		_ = runner.terminateLocked(true)
		stderr := strings.TrimSpace(runner.stderr.String())
		if stderr != "" {
			return sdkBridgeResponse{}, fmt.Errorf(
				"read boxd sdk session response: %w: %s",
				read.err,
				stderr,
			)
		}
		return sdkBridgeResponse{}, fmt.Errorf(
			"read boxd sdk session response: %w",
			read.err,
		)
	}

	var response sessionBridgeResponse
	if err := json.Unmarshal([]byte(read.line), &response); err != nil {
		_ = runner.terminateLocked(true)
		return sdkBridgeResponse{}, fmt.Errorf(
			"decode boxd sdk session response: %w",
			err,
		)
	}
	if response.ID != envelope.ID {
		_ = runner.terminateLocked(true)
		return sdkBridgeResponse{}, fmt.Errorf(
			"boxd sdk session response id = %d, want %d",
			response.ID,
			envelope.ID,
		)
	}
	if response.Error != "" {
		return sdkBridgeResponse{}, errors.New(response.Error)
	}
	if response.Response == nil {
		return sdkBridgeResponse{}, errors.New(
			"boxd sdk session returned no response",
		)
	}
	return *response.Response, nil
}

func (runner *nodeSDKSessionRunner) Close() error {
	runner.mu.Lock()
	defer runner.mu.Unlock()
	return runner.terminateLocked(false)
}

func (runner *nodeSDKSessionRunner) terminateLocked(kill bool) error {
	if runner.closed {
		return nil
	}
	runner.closed = true

	if kill {
		if runner.command.Process != nil {
			_ = runner.command.Process.Kill()
		}
	} else {
		_ = runner.stdin.Close()
	}

	done := make(chan error, 1)
	go func() {
		done <- runner.command.Wait()
	}()

	select {
	case err := <-done:
		if kill {
			return nil
		}
		return err
	case <-time.After(5 * time.Second):
		if runner.command.Process != nil {
			_ = runner.command.Process.Kill()
		}
		<-done
		if kill {
			return nil
		}
		return errors.New("boxd sdk session did not close within 5s")
	}
}
