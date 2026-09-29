package runner

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

func TestRoleCaptureRunsEachRoleThroughTheSameCaptureContract(t *testing.T) {
	toolRoot := t.TempDir()
	request := protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "execution-1",
		ScenarioID:    "scenario-1",
		BaselineSHA:   "base-sha",
		CandidateSHA:  "candidate-sha",
		AttemptNumber: 1,
	}

	for _, test := range []struct {
		name  string
		role  CaptureRole
		label string
		sha   string
	}{
		{
			name:  "base",
			role:  CaptureRoleBase,
			label: "main",
			sha:   request.BaselineSHA,
		},
		{
			name:  "candidate",
			role:  CaptureRoleCandidate,
			label: "feature",
			sha:   request.CandidateSHA,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := filepath.Join(toolRoot, test.name)
			if err := os.MkdirAll(filepath.Join(root, "config"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(
				filepath.Join(root, "config", "environment.rb"),
				[]byte("# rails"),
				0o600,
			); err != nil {
				t.Fatal(err)
			}

			output := filepath.Join(t.TempDir(), test.name+".json")
			fake := &fakeCaptureRunner{}
			capture := &RoleCapture{
				ToolRoot: toolRoot,
				Runner:   fake,
			}

			body, err := capture.Capture(
				context.Background(),
				request,
				CaptureRoleInput{
					Role:                test.role,
					Root:                root,
					Label:               test.label,
					SHA:                 test.sha,
					ScenarioPath:        "/demo",
					PreparedEnvironment: map[string]string{"RAILS_ENV": "test"},
					OutputPath:          output,
				},
			)
			if err != nil {
				t.Fatalf("Capture: %v", err)
			}
			if !json.Valid(body) {
				t.Fatalf("capture body is invalid JSON: %s", body)
			}
			if len(fake.commands) != 1 {
				t.Fatalf("commands = %d, want 1", len(fake.commands))
			}
			command := fake.commands[0]
			if command.Dir != root {
				t.Fatalf("command dir = %q, want %q", command.Dir, root)
			}
			if command.Env["RUNDIFF_EXECUTION_LABEL"] != test.label {
				t.Fatalf(
					"label = %q, want %q",
					command.Env["RUNDIFF_EXECUTION_LABEL"],
					test.label,
				)
			}
			if command.Env["RUNDIFF_EXECUTION_SHA"] != test.sha {
				t.Fatalf(
					"sha = %q, want %q",
					command.Env["RUNDIFF_EXECUTION_SHA"],
					test.sha,
				)
			}
			if command.Env["RUNDIFF_SCENARIO_PATH"] != "/demo" {
				t.Fatalf(
					"scenario path = %q, want /demo",
					command.Env["RUNDIFF_SCENARIO_PATH"],
				)
			}
			if command.Env["RAILS_ENV"] != "test" {
				t.Fatalf("prepared environment was not preserved")
			}
		})
	}
}

func TestRoleCaptureRejectsUnknownRoleBeforeExecution(t *testing.T) {
	fake := &fakeCaptureRunner{}
	capture := &RoleCapture{
		ToolRoot: t.TempDir(),
		Runner:   fake,
	}

	_, err := capture.Capture(
		context.Background(),
		protocol.RequestV1{
			SchemaVersion: protocol.SchemaVersion,
			ExecutionID:   "execution-1",
			ScenarioID:    "scenario-1",
			BaselineSHA:   "base-sha",
			CandidateSHA:  "candidate-sha",
			AttemptNumber: 1,
		},
		CaptureRoleInput{
			Role:       CaptureRole("other"),
			Root:       t.TempDir(),
			SHA:        "sha",
			OutputPath: filepath.Join(t.TempDir(), "capture.json"),
		},
	)
	if err == nil {
		t.Fatal("expected unsupported role error")
	}
	if len(fake.commands) != 0 {
		t.Fatalf("commands = %d, want 0", len(fake.commands))
	}
}
