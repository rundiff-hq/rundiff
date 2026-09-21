package subjectprepare

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/bootstrap"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

const defaultPostgresURL = "postgres://localhost"

var adapterPattern = regexp.MustCompile(
	`(?m)^\s*adapter:\s*["']?([A-Za-z0-9_-]+)`,
)

type RailsDB struct {
	Runner      bootstrap.CommandRunner
	PostgresURL string
}

func NewRailsDB() *RailsDB {
	return &RailsDB{
		Runner:      bootstrap.OSCommandRunner{},
		PostgresURL: os.Getenv("RUNDIFF_LOCAL_POSTGRES_URL"),
	}
}

func (p *RailsDB) Prepare(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	runtimeEnv map[string]string,
) (map[string]string, error) {
	if role != "base" && role != "candidate" {
		return nil, fmt.Errorf("unsupported subject role %q", role)
	}

	persistence, err := detectPersistence(root)
	if err != nil {
		return nil, err
	}

	switch persistence {
	case "postgresql":
		return p.preparePostgres(ctx, request, role, root, runtimeEnv)
	case "sqlite":
		return p.prepareSQLite(ctx, request, role, root, runtimeEnv)
	default:
		return nil, fmt.Errorf("unsupported Rails persistence %q", persistence)
	}
}

func (p *RailsDB) preparePostgres(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	runtimeEnv map[string]string,
) (map[string]string, error) {
	postgresURL := strings.TrimRight(p.PostgresURL, "/")
	if postgresURL == "" {
		postgresURL = defaultPostgresURL
	}
	suffix := executionSuffix(request.ExecutionID)

	env := cloneEnvironment(runtimeEnv)
	env["BUNDLE_GEMFILE"] = filepath.Join(root, "Gemfile")
	env["RAILS_ENV"] = "test"
	env["DATABASE_URL"] = fmt.Sprintf(
		"%s/rundiff_app_%s_%s",
		postgresURL,
		suffix,
		role,
	)
	env["SOLID_QUEUE_DATABASE_URL"] = fmt.Sprintf(
		"%s/rundiff_app_%s_%s_queue",
		postgresURL,
		suffix,
		role,
	)
	env["RUNDIFF_SOLID_QUEUE"] = "1"
	env["RUNDIFF_ASYNC_TRANSPORT"] = "solid_queue"
	env["RUNDIFF_SOLID_QUEUE_DIAGNOSTICS"] = "1"
	env["RUNDIFF_SOLID_QUEUE_START_TIMEOUT_SECONDS"] = "30"
	env["RUNDIFF_QUIESCENCE_TIMEOUT_SECONDS"] = "30"
	env["SOLID_QUEUE_SKIP_RECURRING"] = "true"
	env["SOLID_QUEUE_SUPERVISOR_MODE"] = "async"

	command := []string{
		filepath.Join(root, "bin", "rails"),
		"db:prepare",
		"--trace",
	}
	if _, err := p.runner().Run(ctx, root, env, command); err != nil {
		return nil, err
	}
	return env, nil
}

func (p *RailsDB) prepareSQLite(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	runtimeEnv map[string]string,
) (map[string]string, error) {
	databasePath := filepath.Join(
		root,
		"tmp",
		"rundiff",
		"sqlite",
		fmt.Sprintf(
			"rundiff_subject_%s_%s.sqlite3",
			executionSuffix(request.ExecutionID),
			role,
		),
	)
	if err := os.MkdirAll(filepath.Dir(databasePath), 0o700); err != nil {
		return nil, err
	}
	for _, path := range []string{
		databasePath,
		databasePath + "-wal",
		databasePath + "-shm",
	} {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return nil, err
		}
	}

	env := cloneEnvironment(runtimeEnv)
	env["BUNDLE_GEMFILE"] = filepath.Join(root, "Gemfile")
	env["RAILS_ENV"] = "test"
	env["RUNDIFF_SQLITE_DATABASE"] = databasePath
	env["RUNDIFF_ASYNC_TRANSPORT"] = "test_adapter"
	env["RUNDIFF_QUIESCENCE_TIMEOUT_SECONDS"] = "30"
	env["RUNDIFF_QUIET_PERIOD_SECONDS"] = "0.01"
	delete(env, "DATABASE_URL")
	delete(env, "SOLID_QUEUE_DATABASE_URL")

	command := []string{
		"ruby",
		filepath.Join(root, "bin", "rails"),
		"db:prepare",
		"--trace",
	}
	if _, err := p.runner().Run(ctx, root, env, command); err != nil {
		return nil, err
	}
	return env, nil
}

func (p *RailsDB) runner() bootstrap.CommandRunner {
	if p.Runner != nil {
		return p.Runner
	}
	return bootstrap.OSCommandRunner{}
}

func detectPersistence(root string) (string, error) {
	databaseFile := filepath.Join(root, "config", "database.yml")
	if body, err := os.ReadFile(databaseFile); err == nil {
		matches := adapterPattern.FindAllStringSubmatch(string(body), -1)
		raw := make([]string, 0, len(matches))
		for _, match := range matches {
			raw = append(raw, match[1])
		}
		if len(raw) > 0 {
			mapped := map[string]struct{}{}
			var unsupported []string
			for _, adapter := range raw {
				switch adapter {
				case "postgresql":
					mapped["postgresql"] = struct{}{}
				case "sqlite", "sqlite3":
					mapped["sqlite"] = struct{}{}
				default:
					unsupported = append(unsupported, adapter)
				}
			}
			if len(unsupported) > 0 {
				return "", fmt.Errorf(
					"unsupported Rails database adapter(s): %s",
					strings.Join(uniqueSorted(unsupported), ", "),
				)
			}
			if len(mapped) == 1 {
				for name := range mapped {
					return name, nil
				}
			}
			return "", errors.New(
				"ambiguous Rails persistence in config/database.yml",
			)
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}

	var evidence strings.Builder
	for _, name := range []string{"Gemfile", "Gemfile.lock"} {
		body, err := os.ReadFile(filepath.Join(root, name))
		if err == nil {
			evidence.Write(body)
			evidence.WriteByte('\n')
		} else if !os.IsNotExist(err) {
			return "", err
		}
	}
	contents := evidence.String()
	hasPostgres := regexp.MustCompile(
		`(?m)(gem\s+["']pg["']|^\s{4}pg \()`,
	).MatchString(contents)
	hasSQLite := regexp.MustCompile(
		`(?m)(gem\s+["']sqlite3["']|^\s{4}sqlite3 \()`,
	).MatchString(contents)

	switch {
	case hasPostgres && hasSQLite:
		return "", errors.New(
			"ambiguous Rails persistence from Gemfile evidence",
		)
	case hasPostgres:
		return "postgresql", nil
	case hasSQLite:
		return "sqlite", nil
	default:
		return "", fmt.Errorf(
			"could not discover Rails persistence for %s",
			root,
		)
	}
}

func executionSuffix(executionID string) string {
	value := strings.TrimPrefix(executionID, "github-")
	if len(value) > 12 {
		return value[:12]
	}
	return value
}

func cloneEnvironment(source map[string]string) map[string]string {
	target := make(map[string]string, len(source)+12)
	for key, value := range source {
		target[key] = value
	}
	return target
}

func uniqueSorted(values []string) []string {
	seen := map[string]struct{}{}
	for _, value := range values {
		seen[value] = struct{}{}
	}
	result := make([]string, 0, len(seen))
	for value := range seen {
		result = append(result, value)
	}
	for i := 0; i < len(result); i++ {
		for j := i + 1; j < len(result); j++ {
			if result[j] < result[i] {
				result[i], result[j] = result[j], result[i]
			}
		}
	}
	return result
}
