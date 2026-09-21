package bootstrap

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

type nodeRecordingRunner struct {
	commands [][]string
	envs     []map[string]string
}

func (r *nodeRecordingRunner) Run(_ context.Context, _ string, env map[string]string, command []string) ([]byte, error) {
	r.commands = append(r.commands, append([]string{}, command...))
	copyEnv := map[string]string{}
	for key, value := range env {
		copyEnv[key] = value
	}
	r.envs = append(r.envs, copyEnv)
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
	bootstrap := &NodeNPM{ToolRoot: t.TempDir(), Runner: runner}
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
	if runner.envs[2]["NPM_CONFIG_CACHE"] == "" {
		t.Fatalf("npm ci must receive executor-owned cache: %#v", runner.envs[2])
	}
	if env["RUNDIFF_DEPENDENCY_CACHE_KEY"] == "" || env["RUNDIFF_DEPENDENCY_CACHE_SEED"] != "miss" {
		t.Fatalf("unexpected dependency cache evidence: %#v", env)
	}
	if runner.commands[2][3] != "--prefer-offline" {
		t.Fatalf("npm ci must prefer restored cache: %#v", runner.commands[2])
	}
}


type nodeCachePopulatingRunner struct{}

func (nodeCachePopulatingRunner) Run(_ context.Context, _ string, env map[string]string, command []string) ([]byte, error) {
	switch command[0] {
	case "node":
		return []byte("v24.20.0\n"), nil
	case "npm":
		if len(command) > 1 && command[1] == "--version" {
			return []byte("11.19.0\n"), nil
		}
		cache := env["NPM_CONFIG_CACHE"]
		if err := os.MkdirAll(cache, 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(filepath.Join(cache, "artifact"), []byte("cached"), 0o600); err != nil {
			return nil, err
		}
		return nil, nil
	default:
		return nil, nil
	}
}

func TestNodeNPMReusesSameLockCacheAcrossRoles(t *testing.T) {
	toolRoot := t.TempDir()
	base := filepath.Join(t.TempDir(), "base")
	candidate := filepath.Join(t.TempDir(), "candidate")
	for _, root := range []string{base, candidate} {
		if err := os.MkdirAll(root, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "package.json"), []byte("{\"name\":\"fixture\",\"version\":\"1.0.0\"}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "package-lock.json"), []byte("{\"name\":\"fixture\",\"version\":\"1.0.0\",\"lockfileVersion\":3,\"packages\":{}}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	bootstrap := &NodeNPM{ToolRoot: toolRoot, Runner: nodeCachePopulatingRunner{}}
	baseEnv, err := bootstrap.Bootstrap(context.Background(), "base", base)
	if err != nil {
		t.Fatal(err)
	}
	candidateEnv, err := bootstrap.Bootstrap(context.Background(), "candidate", candidate)
	if err != nil {
		t.Fatal(err)
	}
	if baseEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"] != "miss" {
		t.Fatalf("base seed = %q, want miss", baseEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"])
	}
	if candidateEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"] != "hit" {
		t.Fatalf("candidate seed = %q, want hit", candidateEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"])
	}
	if baseEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] != candidateEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] {
		t.Fatal("same Node lock identity must reuse one cache entry")
	}
}
