package workspace

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

type Prepared struct {
	Root                 string
	BaselineRoot         string
	CandidateRoot        string
	Environment          []string
	BaselineEnvironment          map[string]string
	CandidateEnvironment         map[string]string
	BaselineSubjectEnvironment   map[string]string
	CandidateSubjectEnvironment  map[string]string
}

type Manager interface {
	Prepare(context.Context, protocol.RequestV1, journal.Recorder) (Prepared, error)
	Clone(context.Context, protocol.RequestV1, Prepared, journal.Recorder) (Prepared, error)
	Teardown(context.Context, protocol.RequestV1, Prepared, journal.Recorder) error
}

type GitWorktrees struct {
	RepositoryRoot string
	BaseDir        string
}

func NewGitWorktrees(repositoryRoot string) *GitWorktrees {
	return &GitWorktrees{
		RepositoryRoot: repositoryRoot,
		BaseDir:        filepath.Join(repositoryRoot, "tmp", "rundiff", "go-workspaces"),
	}
}

func (g *GitWorktrees) Prepare(
	ctx context.Context,
	request protocol.RequestV1,
	recorder journal.Recorder,
) (Prepared, error) {
	if request.Context.Repository != "" &&
		request.Context.CandidateRepository != "" &&
		request.Context.Repository != request.Context.CandidateRepository {
		return Prepared{}, errors.New("Go workspace currently supports same-repository candidates only")
	}
	if strings.TrimSpace(g.RepositoryRoot) == "" {
		return Prepared{}, errors.New("repository root is required")
	}

	root := filepath.Join(g.BaseDir, safeID(request.ExecutionID))
	prepared := Prepared{
		Root:          root,
		BaselineRoot:  filepath.Join(root, "base"),
		CandidateRoot: filepath.Join(root, "candidate"),
	}

	_ = g.removeWorktree(ctx, prepared.BaselineRoot)
	_ = g.removeWorktree(ctx, prepared.CandidateRoot)
	_ = os.RemoveAll(root)
	if err := os.MkdirAll(root, 0o700); err != nil {
		return Prepared{}, err
	}

	if err := recorder.Append(resourceEntry(
		request,
		"resource_created",
		"workspace",
		root,
	)); err != nil {
		_ = os.RemoveAll(root)
		return Prepared{}, err
	}

	prepared.Environment = []string{
		"RUNDIFF_PREPARED_BY=go",
		"RUNDIFF_PREPARED_WORKSPACE_ROOT=" + prepared.Root,
		"RUNDIFF_PREPARED_BASELINE_ROOT=" + prepared.BaselineRoot,
		"RUNDIFF_PREPARED_CANDIDATE_ROOT=" + prepared.CandidateRoot,
	}
	return prepared, nil
}

func (g *GitWorktrees) Clone(
	ctx context.Context,
	request protocol.RequestV1,
	prepared Prepared,
	recorder journal.Recorder,
) (Prepared, error) {
	if err := g.git(ctx, "fetch", "--prune", "origin"); err != nil {
		return prepared, err
	}
	for _, sha := range []string{request.BaselineSHA, request.CandidateSHA} {
		if err := g.git(ctx, "cat-file", "-e", sha+"^{commit}"); err != nil {
			return prepared, err
		}
	}

	if err := g.git(
		ctx,
		"worktree",
		"add",
		"--detach",
		prepared.BaselineRoot,
		request.BaselineSHA,
	); err != nil {
		return prepared, err
	}
	if err := recorder.Append(resourceEntry(
		request,
		"resource_created",
		"git_worktree",
		prepared.BaselineRoot,
	)); err != nil {
		return prepared, err
	}

	if err := g.git(
		ctx,
		"worktree",
		"add",
		"--detach",
		prepared.CandidateRoot,
		request.CandidateSHA,
	); err != nil {
		return prepared, err
	}
	if err := recorder.Append(resourceEntry(
		request,
		"resource_created",
		"git_worktree",
		prepared.CandidateRoot,
	)); err != nil {
		return prepared, err
	}

	return prepared, nil
}

func (g *GitWorktrees) Teardown(
	ctx context.Context,
	request protocol.RequestV1,
	prepared Prepared,
	recorder journal.Recorder,
) error {
	var failures []error

	for _, path := range []string{prepared.CandidateRoot, prepared.BaselineRoot} {
		if path == "" {
			continue
		}
		if err := g.removeWorktree(ctx, path); err != nil {
			failures = append(failures, err)
		}
		if err := recorder.Append(resourceEntry(
			request,
			"resource_removed",
			"git_worktree",
			path,
		)); err != nil {
			failures = append(failures, err)
		}
	}

	if prepared.Root != "" {
		if err := os.RemoveAll(prepared.Root); err != nil {
			failures = append(failures, err)
		}
		if err := recorder.Append(resourceEntry(
			request,
			"resource_removed",
			"workspace",
			prepared.Root,
		)); err != nil {
			failures = append(failures, err)
		}
	}

	if err := g.git(ctx, "worktree", "prune"); err != nil {
		failures = append(failures, err)
	}
	return errors.Join(failures...)
}

func (g *GitWorktrees) removeWorktree(ctx context.Context, path string) error {
	if path == "" {
		return nil
	}
	command := exec.CommandContext(
		ctx,
		"git",
		"worktree",
		"remove",
		"--force",
		path,
	)
	command.Dir = g.RepositoryRoot
	if _, err := command.CombinedOutput(); err != nil {
		if os.IsNotExist(err) || !fileExists(path) {
			return nil
		}
		return fmt.Errorf("git worktree remove %s: %w", path, err)
	}
	return nil
}

func (g *GitWorktrees) git(ctx context.Context, args ...string) error {
	command := exec.CommandContext(ctx, "git", args...)
	command.Dir = g.RepositoryRoot
	_, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return nil
}

func resourceEntry(
	request protocol.RequestV1,
	kind string,
	resourceKind string,
	resource string,
) journal.Entry {
	return journal.Entry{
		Kind:          kind,
		ExecutionID:   request.ExecutionID,
		AttemptNumber: request.AttemptNumber,
		ResourceKind:  resourceKind,
		Resource:      resource,
	}
}

func safeID(value string) string {
	var builder strings.Builder
	for _, character := range value {
		switch {
		case character >= 'a' && character <= 'z':
			builder.WriteRune(character)
		case character >= 'A' && character <= 'Z':
			builder.WriteRune(character)
		case character >= '0' && character <= '9':
			builder.WriteRune(character)
		case character == '-', character == '_', character == '.':
			builder.WriteRune(character)
		default:
			builder.WriteRune('_')
		}
	}
	if builder.Len() == 0 {
		return "execution"
	}
	return builder.String()
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
