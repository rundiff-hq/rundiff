package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/agent"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/controlplane"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/executor"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/runner"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		usage(stderr)
		return 2
	}

	switch args[0] {
	case "validate":
		return runValidate(args[1:], stdout, stderr)
	case "reference":
		return runReference(args[1:], stdout, stderr)
	case "agent":
		return runAgent(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command %q\n", args[0])
		usage(stderr)
		return 2
	}
}

func runValidate(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("validate", flag.ContinueOnError)
	flags.SetOutput(stderr)
	requestPath := flags.String("request", "", "Request v1 JSON path")
	resultPath := flags.String("result", "", "Result v1 JSON path")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *requestPath == "" && *resultPath == "" {
		fmt.Fprintln(stderr, "validate requires --request and/or --result")
		return 2
	}
	if *requestPath != "" {
		if _, err := protocol.LoadRequest(*requestPath); err != nil {
			fmt.Fprintf(stderr, "invalid request: %v\n", err)
			return 1
		}
	}
	if *resultPath != "" {
		if _, err := protocol.LoadResult(*resultPath); err != nil {
			fmt.Fprintf(stderr, "invalid result: %v\n", err)
			return 1
		}
	}
	fmt.Fprintln(stdout, "ok")
	return 0
}

func runReference(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("reference", flag.ContinueOnError)
	flags.SetOutput(stderr)
	requestPath := flags.String("request", "", "Request v1 JSON path")
	resultPath := flags.String("result", "", "Result v1 JSON path")
	journalPath := flags.String("journal", "", "Resource Journal JSONL path")
	cwd := flags.String("cwd", ".", "Working directory for the reference adapter")
	timeout := flags.Duration("timeout", 35*time.Minute, "Overall reference execution timeout")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *requestPath == "" || *resultPath == "" {
		fmt.Fprintln(stderr, "reference requires --request and --result")
		return 2
	}
	command := flags.Args()
	if len(command) == 0 {
		fmt.Fprintln(stderr, "reference requires a command after --")
		return 2
	}
	if *journalPath == "" {
		*journalPath = *resultPath + ".journal.jsonl"
	}

	request, err := protocol.LoadRequest(*requestPath)
	if err != nil {
		fmt.Fprintf(stderr, "load request: %v\n", err)
		return 1
	}

	resourceJournal, err := journal.Open(*journalPath)
	if err != nil {
		fmt.Fprintf(stderr, "open resource journal: %v\n", err)
		return 1
	}
	defer resourceJournal.Close()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	engine := executor.New(resourceJournal, runner.Process{
		Command: command,
		Dir:     *cwd,
		Stdout:  stdout,
		Stderr:  stderr,
	})
	result, err := engine.Execute(ctx, request)
	if err != nil {
		result = protocol.Failed("RunDiff::Executor::GoSupervisorError", err.Error())
	}
	if err := protocol.WriteResult(*resultPath, result); err != nil {
		fmt.Fprintf(stderr, "write result: %v\n", err)
		return 1
	}

	fmt.Fprintf(stdout, "execution_id=%s\n", request.ExecutionID)
	fmt.Fprintf(stdout, "attempt_number=%d\n", request.AttemptNumber)
	fmt.Fprintf(stdout, "result_status=%s\n", result.Status)
	if result.ErrorClass != nil {
		fmt.Fprintf(stdout, "result_error_class=%s\n", *result.ErrorClass)
	}

	return 0
}


func runAgent(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("agent", flag.ContinueOnError)
	flags.SetOutput(stderr)
	controlPlaneURL := flags.String("control-plane-url", "", "RunDiff control-plane base URL")
	tokenEnv := flags.String("token-env", "RUNDIFF_EXECUTOR_TOKEN", "Environment variable containing the executor control token")
	executionID := flags.String("execution-id", "", "Exact execution ID")
	attemptNumber := flags.Int("attempt", 0, "Exact attempt number")
	resultPath := flags.String("result", "", "Optional Result v1 JSON output path")
	journalPath := flags.String("journal", "", "Resource Journal JSONL path")
	cwd := flags.String("cwd", ".", "Working directory for the reference adapter")
	heartbeatInterval := flags.Duration("heartbeat-interval", 20*time.Second, "Heartbeat interval")
	timeout := flags.Duration("timeout", 35*time.Minute, "Overall execution timeout")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *controlPlaneURL == "" || *executionID == "" || *attemptNumber < 1 {
		fmt.Fprintln(stderr, "agent requires --control-plane-url, --execution-id, and --attempt")
		return 2
	}
	command := flags.Args()
	if len(command) == 0 {
		fmt.Fprintln(stderr, "agent requires a reference command after --")
		return 2
	}
	token := os.Getenv(*tokenEnv)
	if token == "" {
		fmt.Fprintf(stderr, "%s is required\n", *tokenEnv)
		return 2
	}
	if *journalPath == "" {
		*journalPath = fmt.Sprintf("tmp/rundiff/go-executor/%s.%d.journal.jsonl", *executionID, *attemptNumber)
	}

	resourceJournal, err := journal.Open(*journalPath)
	if err != nil {
		fmt.Fprintf(stderr, "open resource journal: %v\n", err)
		return 1
	}
	defer resourceJournal.Close()

	engine := executor.New(resourceJournal, runner.Process{
		Command: command,
		Dir:     *cwd,
		Stdout:  stdout,
		Stderr:  stderr,
	})
	managed := &agent.Agent{
		ControlPlane: &controlplane.Client{
			BaseURL: *controlPlaneURL,
			Token:   token,
		},
		Engine:            engine,
		Journal:           resourceJournal,
		HeartbeatInterval: *heartbeatInterval,
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	outcome, err := managed.Run(ctx, controlplane.Assignment{
		ExecutionID:   *executionID,
		AttemptNumber: *attemptNumber,
	})
	if err != nil {
		fmt.Fprintf(stderr, "agent execution failed: %v\n", err)
		return 1
	}
	if *resultPath != "" {
		if err := protocol.WriteResult(*resultPath, outcome.Result); err != nil {
			fmt.Fprintf(stderr, "write result: %v\n", err)
			return 1
		}
	}

	fmt.Fprintf(stdout, "execution_id=%s\n", outcome.Request.ExecutionID)
	fmt.Fprintf(stdout, "attempt_number=%d\n", outcome.Request.AttemptNumber)
	fmt.Fprintf(stdout, "result_status=%s\n", outcome.Result.Status)
	fmt.Fprintf(stdout, "submission_status=%s\n", outcome.Submission.Status)
	return 0
}

func usage(writer io.Writer) {
	fmt.Fprintln(writer, "RunDiff managed Go Executor")
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "Commands:")
	fmt.Fprintln(writer, "  validate  validate frozen Request v1 / Result v1 JSON")
	fmt.Fprintln(writer, "  reference supervise an existing reference adapter through Request v1 / Result v1")
	fmt.Fprintln(writer, "  agent     claim an exact attempt, heartbeat it, execute, and submit Result v1")
}
