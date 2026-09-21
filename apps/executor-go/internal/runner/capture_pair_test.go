package runner

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/workspace"
)

type fakeCaptureRunner struct {
	commands []CaptureCommand
}

func (f *fakeCaptureRunner) Run(
	_ context.Context,
	command CaptureCommand,
) error {
	f.commands = append(f.commands, command)
	if output := command.Env["RUNDIFF_OUTPUT"]; output != "" {
		payload := map[string]any{
			"id":          command.Env["RUNDIFF_EXECUTION_LABEL"],
			"run_id":      command.Env["RUNDIFF_RUN_ID"],
			"scenario_id": command.Env["RUNDIFF_SCENARIO_ID"],
			"measurements": map[string]any{
				"duration_ms":     10,
				"sql_queries":     1,
				"background_jobs": 0,
				"emails":          0,
				"http_requests":   0,
				"errors":          0,
			},
			"attributions":         map[string]any{},
			"durable_observations": []any{},
		}
		body, _ := json.Marshal(payload)
		return os.WriteFile(output, body, 0o600)
	}
	if len(command.Command) == 6 &&
		strings.HasSuffix(command.Command[1], "rundiff_compare_captures.rb") {
		base, _ := os.ReadFile(command.Command[2])
		var execution map[string]any
		_ = json.Unmarshal(base, &execution)
		pair, _ := json.Marshal(map[string]any{
			"schema_version": "1",
			"run_id":         execution["run_id"],
			"result":         map[string]any{"merge_recommendation": "allow"},
		})
		return os.WriteFile(command.Command[5], pair, 0o600)
	}
	return nil
}

type nopJournal struct{}

func (nopJournal) Append(journal.Entry) error { return nil }

func TestCapturePairOwnsBaseAndCandidateScenarioOrchestration(t *testing.T) {
	toolRoot := t.TempDir()
	base := filepath.Join(toolRoot, "base")
	candidate := filepath.Join(toolRoot, "candidate")
	for _, root := range []string{base, candidate} {
		if err := os.MkdirAll(root, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(
			filepath.Join(root, "rundiff.yml"),
			[]byte("version: 1\nscenario:\n  path: /demo\n"),
			0o600,
		); err != nil {
			t.Fatal(err)
		}
	}
	// changedPaths shells out to Git. Give it a minimal real repository.
	runGit(t, toolRoot, "init")
	runGit(t, toolRoot, "config", "user.email", "test@example.com")
	runGit(t, toolRoot, "config", "user.name", "RunDiff Test")
	if err := os.WriteFile(filepath.Join(toolRoot, "tracked"), []byte("base"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, toolRoot, "add", "tracked")
	runGit(t, toolRoot, "commit", "-m", "base")
	baseSHA := strings.TrimSpace(gitOutput(t, toolRoot, "rev-parse", "HEAD"))
	if err := os.WriteFile(filepath.Join(toolRoot, "tracked"), []byte("candidate"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, toolRoot, "commit", "-am", "candidate")
	candidateSHA := strings.TrimSpace(gitOutput(t, toolRoot, "rev-parse", "HEAD"))

	fake := &fakeCaptureRunner{}
	runner := &CapturePair{ToolRoot: toolRoot, Runner: fake}
	result, err := runner.Run(
		context.Background(),
		protocol.RequestV1{
			SchemaVersion: protocol.SchemaVersion,
			ExecutionID:   "execution-1",
			ScenarioID:    "scenario-1",
			BaselineSHA:   baseSHA,
			CandidateSHA:  candidateSHA,
			AttemptNumber: 1,
			Context: protocol.ContextV1{
				BaselineRef: "main",
				CandidateRef: "feature",
			},
		},
		workspace.Prepared{
			Root: toolRoot,
			BaselineRoot: base,
			CandidateRoot: candidate,
			BaselineSubjectEnvironment: map[string]string{"RAILS_ENV": "test"},
			CandidateSubjectEnvironment: map[string]string{"RAILS_ENV": "test"},
		},
		nopJournal{},
	)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != "succeeded" {
		t.Fatalf("status = %q", result.Status)
	}
	if len(fake.commands) != 3 {
		t.Fatalf("commands = %d, want base + candidate + compare", len(fake.commands))
	}
	for index, role := range []string{"base", "candidate"} {
		command := fake.commands[index]
		if command.Env["RUNDIFF_SCENARIO_PATH"] != "/demo" {
			t.Fatalf("%s scenario path = %q", role, command.Env["RUNDIFF_SCENARIO_PATH"])
		}
		if command.Env["RAILS_ENV"] != "test" {
			t.Fatalf("%s lost prepared environment", role)
		}
	}
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	_ = gitOutput(t, dir, args...)
}

func gitOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, output)
	}
	return string(output)
}
