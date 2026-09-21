package bootstrap

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

type nodeRecordingRunner struct {
	commands [][]string
}

func (r *nodeRecordingRunner) Run(_ context.Context, _ string, _ map[string]string, command []string) ([]byte, error) {
	r.commands = append(r.commands, append([]string{}, command...))
	switch command[0] {
	case "node":
		return []byte("v24.20.0\n"), nil
	case "npm":
		if len(command) > 1 && command[1] == "--version" {
			return []byte("11.19.0\n"), nil
		}
		return []byte{}, nil
	default:
		return nil, nil
	}
}

func TestNodeNPMBootstrapUsesFrozenCommittedInputs(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "package.json"), []byte("{\"name\":\"fixture\",\"version\":\"1.0.0\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "package-lock.json"), []byte("{\"name\":\"fixture\",\"version\":\"1.0.0\",\"lockfileVersion\":3,\"packages\":{}}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := &nodeRecordingRunner{}
	bootstrap := &NodeNPM{Runner: runner}
	env, err := bootstrap.Bootstrap(context.Background(), "candidate", root)
	if err != nil {
		t.Fatal(err)
	}
	if env["RUNDIFF_SUBJECT_NODE_VERSION"] != "v24.20.0" || env["RUNDIFF_SUBJECT_NPM_VERSION"] != "11.19.0" {
		t.Fatalf("unexpected runtime evidence: %#v", env)
	}
	if len(runner.commands) != 3 || runner.commands[2][0] != "npm" || runner.commands[2][1] != "ci" {
		t.Fatalf("unexpected commands: %#v", runner.commands)
	}
}
