package subjectprepare

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

type fakeCommandRunner struct {
	calls []commandCall
}

type commandCall struct {
	dir     string
	env     map[string]string
	command []string
}

func (r *fakeCommandRunner) Run(
	_ context.Context,
	dir string,
	env map[string]string,
	command []string,
) ([]byte, error) {
	copyEnv := map[string]string{}
	for key, value := range env {
		copyEnv[key] = value
	}
	r.calls = append(r.calls, commandCall{
		dir:     dir,
		env:     copyEnv,
		command: append([]string{}, command...),
	})
	return nil, nil
}

func TestRailsDBPreparesPostgresWithRoleIsolatedState(t *testing.T) {
	root := t.TempDir()
	writeSubject(
		t,
		root,
		"adapter: postgresql\n",
		"gem \"pg\"\n",
	)
	runner := &fakeCommandRunner{}
	preparer := &RailsDB{
		Runner:      runner,
		PostgresURL: "postgres://postgres:postgres@127.0.0.1:5432/",
	}
	request := requestFixture("github-abcdef1234567890")

	base, err := preparer.Prepare(
		context.Background(),
		request,
		"base",
		root,
		map[string]string{"BUNDLE_PATH": "/tmp/bundle"},
	)
	if err != nil {
		t.Fatalf("base Prepare: %v", err)
	}
	candidate, err := preparer.Prepare(
		context.Background(),
		request,
		"candidate",
		root,
		map[string]string{"BUNDLE_PATH": "/tmp/bundle"},
	)
	if err != nil {
		t.Fatalf("candidate Prepare: %v", err)
	}

	if base["DATABASE_URL"] !=
		"postgres://postgres:postgres@127.0.0.1:5432/rundiff_app_abcdef123456_base" {
		t.Fatalf("unexpected base DATABASE_URL: %q", base["DATABASE_URL"])
	}
	if candidate["DATABASE_URL"] !=
		"postgres://postgres:postgres@127.0.0.1:5432/rundiff_app_abcdef123456_candidate" {
		t.Fatalf(
			"unexpected candidate DATABASE_URL: %q",
			candidate["DATABASE_URL"],
		)
	}
	if base["BUNDLE_PATH"] != "/tmp/bundle" {
		t.Fatalf("bootstrap environment missing: %+v", base)
	}
	if len(runner.calls) != 2 {
		t.Fatalf("expected two db:prepare calls, got %d", len(runner.calls))
	}
	if got := strings.Join(runner.calls[0].command, " "); !strings.HasSuffix(
		got,
		"bin/rails db:prepare --trace",
	) {
		t.Fatalf("unexpected command: %s", got)
	}
}

func TestRailsDBPreparesSQLiteAndRemovesStaleSidecars(t *testing.T) {
	root := t.TempDir()
	writeSubject(
		t,
		root,
		"adapter: sqlite3\n",
		"gem \"sqlite3\"\n",
	)
	request := requestFixture("github-abcdef1234567890")
	databasePath := filepath.Join(
		root,
		"tmp",
		"rundiff",
		"sqlite",
		"rundiff_subject_abcdef123456_base.sqlite3",
	)
	if err := os.MkdirAll(filepath.Dir(databasePath), 0o700); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	for _, path := range []string{
		databasePath,
		databasePath + "-wal",
		databasePath + "-shm",
	} {
		if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
			t.Fatalf("WriteFile: %v", err)
		}
	}

	runner := &fakeCommandRunner{}
	preparer := &RailsDB{Runner: runner}
	env, err := preparer.Prepare(
		context.Background(),
		request,
		"base",
		root,
		map[string]string{
			"BUNDLE_PATH":              "/tmp/bundle",
			"DATABASE_URL":             "must-disappear",
			"SOLID_QUEUE_DATABASE_URL": "must-disappear",
		},
	)
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}

	if env["RUNDIFF_SQLITE_DATABASE"] != databasePath {
		t.Fatalf("unexpected sqlite path: %+v", env)
	}
	if _, ok := env["DATABASE_URL"]; ok {
		t.Fatalf("DATABASE_URL leaked into sqlite env: %+v", env)
	}
	if _, ok := env["SOLID_QUEUE_DATABASE_URL"]; ok {
		t.Fatalf("SOLID_QUEUE_DATABASE_URL leaked into sqlite env: %+v", env)
	}
	for _, path := range []string{
		databasePath,
		databasePath + "-wal",
		databasePath + "-shm",
	} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("stale sqlite file still exists: %s", path)
		}
	}
	if len(runner.calls) != 1 ||
		runner.calls[0].command[0] != "ruby" {
		t.Fatalf("unexpected sqlite command: %+v", runner.calls)
	}
}

func TestDetectPersistenceRejectsAmbiguousAdapters(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o700); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	body := "test:\n  adapter: postgresql\nother:\n  adapter: sqlite3\n"
	if err := os.WriteFile(
		filepath.Join(root, "config", "database.yml"),
		[]byte(body),
		0o600,
	); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	_, err := detectPersistence(root)
	if err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguity error, got %v", err)
	}
}

func requestFixture(executionID string) protocol.RequestV1 {
	return protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   executionID,
		ScenarioID:    "scenario",
		BaselineSHA:   "aaa",
		CandidateSHA:  "bbb",
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository:          "demo/repo",
			CandidateRepository: "demo/repo",
		},
	}
}

func writeSubject(
	t *testing.T,
	root string,
	databaseYAML string,
	gemfile string,
) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o700); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(
		filepath.Join(root, "config", "database.yml"),
		[]byte(databaseYAML),
		0o600,
	); err != nil {
		t.Fatalf("database.yml: %v", err)
	}
	if err := os.WriteFile(
		filepath.Join(root, "Gemfile"),
		[]byte(gemfile),
		0o600,
	); err != nil {
		t.Fatalf("Gemfile: %v", err)
	}
}
