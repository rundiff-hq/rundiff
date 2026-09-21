package workspace

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/repositorycapability"
)

var repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

type Prepared struct {
	Root                        string
	RepositoryRoot              string
	BaselineRoot                string
	CandidateRoot               string
	Environment                 []string
	BaselineEnvironment         map[string]string
	CandidateEnvironment        map[string]string
	BaselineSubjectEnvironment  map[string]string
	CandidateSubjectEnvironment map[string]string
	ServicesPrepared            bool
}

type Manager interface {
	Prepare(context.Context, protocol.RequestV1, journal.Recorder) (Prepared, error)
	Clone(context.Context, protocol.RequestV1, Prepared, journal.Recorder) (Prepared, error)
	Teardown(context.Context, protocol.RequestV1, Prepared, journal.Recorder) error
}

type GitWorktrees struct {
	RepositoryRoot string
	BaseDir        string
	RemoteBaseDir  string
	GitBaseURL     string
}

func NewGitWorktrees(repositoryRoot string) *GitWorktrees {
	return &GitWorktrees{
		RepositoryRoot: repositoryRoot,
		BaseDir:        filepath.Join(repositoryRoot, "tmp", "rundiff", "go-workspaces"),
		RemoteBaseDir:  filepath.Join(os.TempDir(), "rundiff", "go-repositories"),
		GitBaseURL:     os.Getenv("RUNDIFF_GITHUB_GIT_BASE_URL"),
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

	remote := repositorycapability.Token(ctx) != ""
	baseDir := g.BaseDir
	repositoryRoot := g.RepositoryRoot
	if remote {
		if err := validateRemoteRequest(request); err != nil {
			return Prepared{}, err
		}
		baseDir = g.RemoteBaseDir
		if strings.TrimSpace(baseDir) == "" {
			baseDir = filepath.Join(os.TempDir(), "rundiff", "go-repositories")
		}
	}

	root := filepath.Join(baseDir, safeID(request.ExecutionID))
	if remote {
		repositoryRoot = filepath.Join(root, "repository")
	}
	prepared := Prepared{
		Root:           root,
		RepositoryRoot: repositoryRoot,
		BaselineRoot:   filepath.Join(root, "base"),
		CandidateRoot:  filepath.Join(root, "candidate"),
	}

	_ = g.removeWorktree(ctx, repositoryRoot, prepared.BaselineRoot)
	_ = g.removeWorktree(ctx, repositoryRoot, prepared.CandidateRoot)
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
		"RUNDIFF_PREPARED_REPOSITORY_ROOT=" + prepared.RepositoryRoot,
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
	token := repositorycapability.Token(ctx)
	if token != "" {
		if err := g.prepareRemoteRepository(ctx, request, prepared.RepositoryRoot, token); err != nil {
			return prepared, err
		}
	} else {
		if err := g.gitAt(ctx, prepared.RepositoryRoot, nil, "fetch", "--prune", "origin"); err != nil {
			return prepared, err
		}
	}

	for _, sha := range []string{request.BaselineSHA, request.CandidateSHA} {
		if err := g.gitAt(ctx, prepared.RepositoryRoot, nil, "cat-file", "-e", sha+"^{commit}"); err != nil {
			return prepared, err
		}
	}

	if err := g.gitAt(
		ctx,
		prepared.RepositoryRoot,
		nil,
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

	if err := g.gitAt(
		ctx,
		prepared.RepositoryRoot,
		nil,
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
		if err := g.removeWorktree(ctx, prepared.RepositoryRoot, path); err != nil {
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

	if prepared.RepositoryRoot != "" && fileExists(prepared.RepositoryRoot) {
		if err := g.gitAt(ctx, prepared.RepositoryRoot, nil, "worktree", "prune"); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func (g *GitWorktrees) prepareRemoteRepository(
	ctx context.Context,
	request protocol.RequestV1,
	repositoryRoot string,
	token string,
) error {
	baseURL, err := g.normalizedGitBaseURL()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(repositoryRoot), 0o700); err != nil {
		return err
	}
	if err := g.runAt(ctx, filepath.Dir(repositoryRoot), nil, "git", "init", repositoryRoot); err != nil {
		return err
	}
	if err := g.gitAt(
		ctx,
		repositoryRoot,
		nil,
		"remote",
		"add",
		"origin",
		baseURL+"/"+request.Context.Repository+".git",
	); err != nil {
		return err
	}

	auth := gitAuthEnvironment(baseURL, token)
	return g.gitAt(
		ctx,
		repositoryRoot,
		auth,
		"fetch",
		"--no-tags",
		"origin",
		"+refs/heads/"+request.Context.BaselineRef+":refs/remotes/origin/rundiff-base",
		fmt.Sprintf(
			"+refs/pull/%d/head:refs/remotes/origin/rundiff-candidate",
			request.Context.PullRequestNumber,
		),
	)
}

func validateRemoteRequest(request protocol.RequestV1) error {
	if !repositoryPattern.MatchString(request.Context.Repository) {
		return errors.New("executor repository must use owner/name form")
	}
	if request.Context.CandidateRepository != "" &&
		request.Context.CandidateRepository != request.Context.Repository {
		return errors.New("Go workspace currently supports same-repository candidates only")
	}
	if request.Context.PullRequestNumber < 1 {
		return errors.New("remote GitHub workspace requires pull_request_number")
	}
	if strings.TrimSpace(request.Context.BaselineRef) == "" {
		return errors.New("remote GitHub workspace requires baseline_ref")
	}
	return nil
}

func (g *GitWorktrees) normalizedGitBaseURL() (string, error) {
	value := strings.TrimRight(strings.TrimSpace(g.GitBaseURL), "/")
	if value == "" {
		value = "https://github.com"
	}
	parsed, err := url.Parse(value)
	if err != nil ||
		(parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Host == "" {
		return "", errors.New("Git base URL must be an absolute HTTP(S) URL")
	}
	return value, nil
}

func gitAuthEnvironment(baseURL, token string) []string {
	basic := base64.StdEncoding.EncodeToString([]byte("x-access-token:" + token))
	environment := safeGitEnvironment()
	environment = append(
		environment,
		"GIT_TERMINAL_PROMPT=0",
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http."+baseURL+"/.extraheader",
		"GIT_CONFIG_VALUE_0=AUTHORIZATION: basic "+basic,
	)
	return environment
}

func safeGitEnvironment() []string {
	keys := []string{
		"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
		"SSL_CERT_FILE", "SSL_CERT_DIR",
	}
	environment := make([]string, 0, len(keys))
	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	return environment
}

func (g *GitWorktrees) removeWorktree(
	ctx context.Context,
	repositoryRoot string,
	path string,
) error {
	if path == "" || repositoryRoot == "" || !fileExists(repositoryRoot) {
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
	command.Dir = repositoryRoot
	if _, err := command.CombinedOutput(); err != nil {
		if os.IsNotExist(err) || !fileExists(path) {
			return nil
		}
		return fmt.Errorf("git worktree remove %s: %w", path, err)
	}
	return nil
}

func (g *GitWorktrees) gitAt(
	ctx context.Context,
	dir string,
	environment []string,
	args ...string,
) error {
	return g.runAt(ctx, dir, environment, "git", args...)
}

func (g *GitWorktrees) runAt(
	ctx context.Context,
	dir string,
	environment []string,
	commandName string,
	args ...string,
) error {
	command := exec.CommandContext(ctx, commandName, args...)
	command.Dir = dir
	if environment != nil {
		command.Env = environment
	}
	_, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w", commandName, strings.Join(args, " "), err)
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
