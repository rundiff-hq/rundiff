package workspace

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/repositorycapability"
)

type memoryRecorder struct {
	entries []journal.Entry
}

func (r *memoryRecorder) Append(entry journal.Entry) error {
	r.entries = append(r.entries, entry)
	return nil
}

func TestGitWorktreesPreparesExactBaselineAndCandidate(t *testing.T) {
	root, baselineSHA, candidateSHA := gitFixture(t)
	recorder := &memoryRecorder{}
	manager := NewGitWorktrees(root)
	request := protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "exec/worktree",
		ScenarioID:    "scenario",
		BaselineSHA:   baselineSHA,
		CandidateSHA:  candidateSHA,
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository:          "demo/repo",
			CandidateRepository: "demo/repo",
		},
	}

	prepared, err := manager.Prepare(context.Background(), request, recorder)
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	prepared, err = manager.Clone(context.Background(), request, prepared, recorder)
	if err != nil {
		t.Fatalf("Clone: %v", err)
	}

	if got := gitOutput(t, prepared.BaselineRoot, "rev-parse", "HEAD"); got != baselineSHA {
		t.Fatalf("baseline HEAD=%s want=%s", got, baselineSHA)
	}
	if got := gitOutput(t, prepared.CandidateRoot, "rev-parse", "HEAD"); got != candidateSHA {
		t.Fatalf("candidate HEAD=%s want=%s", got, candidateSHA)
	}
	if !containsEnv(prepared.Environment, "RUNDIFF_PREPARED_BY=go") {
		t.Fatalf("missing prepared-workspace environment: %v", prepared.Environment)
	}

	if err := manager.Teardown(context.Background(), request, prepared, recorder); err != nil {
		t.Fatalf("Teardown: %v", err)
	}
	if _, err := os.Stat(prepared.Root); !os.IsNotExist(err) {
		t.Fatalf("workspace still exists: %s", prepared.Root)
	}
}

func gitFixture(t *testing.T) (string, string, string) {
	t.Helper()
	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	run(t, base, "git", "init", "--bare", origin)

	seed := filepath.Join(base, "seed")
	run(t, base, "git", "init", seed)
	run(t, seed, "git", "config", "user.email", "rundiff@example.test")
	run(t, seed, "git", "config", "user.name", "RunDiff")
	if err := os.WriteFile(filepath.Join(seed, "value.txt"), []byte("base\n"), 0o600); err != nil {
		t.Fatalf("write base: %v", err)
	}
	run(t, seed, "git", "add", "value.txt")
	run(t, seed, "git", "commit", "-m", "base")
	baselineSHA := gitOutput(t, seed, "rev-parse", "HEAD")

	if err := os.WriteFile(filepath.Join(seed, "value.txt"), []byte("candidate\n"), 0o600); err != nil {
		t.Fatalf("write candidate: %v", err)
	}
	run(t, seed, "git", "commit", "-am", "candidate")
	candidateSHA := gitOutput(t, seed, "rev-parse", "HEAD")
	run(t, seed, "git", "remote", "add", "origin", origin)
	run(t, seed, "git", "push", "origin", "HEAD:main")

	checkout := filepath.Join(base, "checkout")
	run(t, base, "git", "clone", origin, checkout)
	return checkout, baselineSHA, candidateSHA
}

func run(t *testing.T, dir string, command string, args ...string) {
	t.Helper()
	cmd := exec.Command(command, args...)
	cmd.Dir = dir
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s %s: %v: %s", command, strings.Join(args, " "), err, output)
	}
}

func gitOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(args, " "), err, output)
	}
	return strings.TrimSpace(string(output))
}

func containsEnv(environment []string, expected string) bool {
	for _, item := range environment {
		if item == expected {
			return true
		}
	}
	return false
}


func TestGitWorktreesUsesIsolatedRootForRepositoryCapability(t *testing.T) {
	toolRoot := filepath.Join(t.TempDir(), "tool")
	remoteRoot := filepath.Join(t.TempDir(), "customer-repositories")
	manager := NewGitWorktrees(toolRoot)
	manager.RemoteBaseDir = remoteRoot

	request := protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "exec/external",
		ScenarioID:    "scenario",
		BaselineSHA:   strings.Repeat("a", 40),
		CandidateSHA:  strings.Repeat("b", 40),
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository:          "customer/example-node",
			CandidateRepository: "customer/example-node",
			PullRequestNumber:   7,
			BaselineRef:         "main",
			CandidateRef:        "regression",
		},
	}

	ctx := repositorycapability.WithToken(context.Background(), "repo-token")
	prepared, err := manager.Prepare(ctx, request, &memoryRecorder{})
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	if !strings.HasPrefix(prepared.Root, remoteRoot+string(os.PathSeparator)) {
		t.Fatalf("remote workspace root = %q, want under %q", prepared.Root, remoteRoot)
	}
	if strings.HasPrefix(prepared.Root, toolRoot+string(os.PathSeparator)) {
		t.Fatalf("customer workspace must not be nested under tool root: %q", prepared.Root)
	}
	if prepared.RepositoryRoot != filepath.Join(prepared.Root, "repository") {
		t.Fatalf("repository root = %q", prepared.RepositoryRoot)
	}
	for _, item := range prepared.Environment {
		if strings.Contains(item, "repo-token") {
			t.Fatal("repository capability must not enter prepared environment")
		}
	}

	if err := manager.Teardown(ctx, request, prepared, &memoryRecorder{}); err != nil {
		t.Fatalf("Teardown: %v", err)
	}
}
