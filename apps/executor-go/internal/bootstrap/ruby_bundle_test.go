package bootstrap

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeRunner struct {
	calls []fakeCall
}

type fakeCall struct {
	dir     string
	env     map[string]string
	command []string
}

func (r *fakeRunner) Run(
	_ context.Context,
	dir string,
	env map[string]string,
	command []string,
) ([]byte, error) {
	copyEnv := map[string]string{}
	for key, value := range env {
		copyEnv[key] = value
	}
	r.calls = append(r.calls, fakeCall{
		dir:     dir,
		env:     copyEnv,
		command: append([]string{}, command...),
	})

	switch command[0] {
	case "ruby":
		return []byte("3.4.10"), nil
	case "gem":
		return []byte("true"), nil
	case "bundle":
		return []byte("The Gemfile's dependencies are satisfied"), nil
	default:
		return nil, errors.New("unexpected command")
	}
}

func TestRubyBundleProducesFrozenSharedRuntimeEnvironment(t *testing.T) {
	toolRoot := t.TempDir()
	base := filepath.Join(toolRoot, "base")
	candidate := filepath.Join(toolRoot, "candidate")
	writeRubySubject(t, base)
	writeRubySubject(t, candidate)

	runner := &fakeRunner{}
	bootstrap := &RubyBundle{ToolRoot: toolRoot, Runner: runner}

	baseEnv, err := bootstrap.Bootstrap(context.Background(), "base", base)
	if err != nil {
		t.Fatalf("base Bootstrap: %v", err)
	}
	candidateEnv, err := bootstrap.Bootstrap(
		context.Background(),
		"candidate",
		candidate,
	)
	if err != nil {
		t.Fatalf("candidate Bootstrap: %v", err)
	}

	if baseEnv["BUNDLE_GEMFILE"] != filepath.Join(base, "Gemfile") {
		t.Fatalf("unexpected base Gemfile: %q", baseEnv["BUNDLE_GEMFILE"])
	}
	if candidateEnv["BUNDLE_GEMFILE"] != filepath.Join(candidate, "Gemfile") {
		t.Fatalf("unexpected candidate Gemfile: %q", candidateEnv["BUNDLE_GEMFILE"])
	}
	if baseEnv["BUNDLE_PATH"] != candidateEnv["BUNDLE_PATH"] {
		t.Fatalf(
			"same lockfile must share cache: base=%q candidate=%q",
			baseEnv["BUNDLE_PATH"],
			candidateEnv["BUNDLE_PATH"],
		)
	}
	if baseEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] == "" ||
		baseEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] != candidateEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] {
		t.Fatalf("same dependency identity must expose one cache key: base=%#v candidate=%#v", baseEnv, candidateEnv)
	}
	if baseEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"] != "hit" {
		t.Fatalf("bundle check success must report cache hit: %#v", baseEnv)
	}
	if baseEnv["BUNDLE_DEPLOYMENT"] != "true" ||
		baseEnv["BUNDLE_FROZEN"] != "true" {
		t.Fatalf("bootstrap is not frozen: %+v", baseEnv)
	}
	if baseEnv["RUNDIFF_SUBJECT_BUNDLER_VERSION"] != "4.0.13" {
		t.Fatalf("unexpected bundler version: %+v", baseEnv)
	}
}

func TestSafeHostEnvironmentDoesNotForwardRunDiffSecrets(t *testing.T) {
	t.Setenv("RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN", "secret")
	t.Setenv("RUNDIFF_GITHUB_WEBHOOK_SECRET", "secret")
	t.Setenv("SSH_AUTH_SOCK", "/private/agent.sock")
	t.Setenv("PATH", "/usr/bin")

	environment := safeHostEnvironment()
	joined := strings.Join(environment, "\n")
	if !strings.Contains(joined, "PATH=/usr/bin") {
		t.Fatalf("PATH missing from safe environment: %v", environment)
	}
	for _, forbidden := range []string{
		"RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN",
		"RUNDIFF_GITHUB_WEBHOOK_SECRET",
		"SSH_AUTH_SOCK",
	} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("unsafe key %s forwarded: %v", forbidden, environment)
		}
	}
}

func TestRubyBundleRejectsMismatchedRubyLine(t *testing.T) {
	root := t.TempDir()
	writeRubySubject(t, root)
	if err := os.WriteFile(filepath.Join(root, ".ruby-version"), []byte("3.3.9\n"), 0o600); err != nil {
		t.Fatalf("write .ruby-version: %v", err)
	}

	bootstrap := &RubyBundle{
		ToolRoot: root,
		Runner:   &fakeRunner{},
	}
	_, err := bootstrap.Bootstrap(context.Background(), "base", root)
	if err == nil || !strings.Contains(err.Error(), "requires Ruby 3.3.9") {
		t.Fatalf("expected Ruby mismatch error, got %v", err)
	}
}

func writeRubySubject(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "Gemfile"), []byte("source \"https://rubygems.org\"\n"), 0o600); err != nil {
		t.Fatalf("write Gemfile: %v", err)
	}
	lock := "GEM\n  specs:\n\nRUBY VERSION\n   ruby 3.4.10\n\nBUNDLED WITH\n   4.0.13\n"
	if err := os.WriteFile(filepath.Join(root, "Gemfile.lock"), []byte(lock), 0o600); err != nil {
		t.Fatalf("write Gemfile.lock: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".ruby-version"), []byte("3.4.10\n"), 0o600); err != nil {
		t.Fatalf("write .ruby-version: %v", err)
	}
}
