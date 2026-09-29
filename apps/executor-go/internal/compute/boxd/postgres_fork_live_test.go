package boxd

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

func TestLiveRunningPostgresForkIsolation(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live running PostgreSQL fork proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live running PostgreSQL fork proof")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live running PostgreSQL fork proof")
	}

	client, err := NewSessionPairSDK(
		"node",
		"sdkbridge/session.mjs",
		"sdkbridge/bridge.mjs",
	)
	if err != nil {
		t.Fatalf("start pair SDK sessions: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close pair SDK sessions: %v", closeErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	parentName := "rundiff-pg-" + proofID
	baselineName := "rundiff-pgb-" + proofID
	candidateName := "rundiff-pgc-" + proofID

	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create PostgreSQL parent: %v", err)
	}
	defer removeMachine(t, client, parent)

	prepareStarted := time.Now()
	if _, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc", runningPostgresPrepareScript,
	}); err != nil {
		t.Fatalf("prepare running PostgreSQL parent: %v", err)
	}
	t.Logf(
		"postgres.parent_prepare_ms=%d",
		time.Since(prepareStarted).Milliseconds(),
	)

	parentStartedAt := postgresContainerStartedAt(t, ctx, client, parent)
	parentState := postgresProbeState(t, ctx, client, parent)
	if parentState != "golden" {
		t.Fatalf("parent state before fork = %q, want golden", parentState)
	}

	forkStarted := time.Now()
	pair, err := compute.ForkPair(
		ctx,
		client,
		parent.Name,
		baselineName,
		candidateName,
	)
	if err != nil {
		t.Fatalf("fork running PostgreSQL pair: %v", err)
	}
	t.Logf(
		"provider.running_postgres_fork_pair_ready_ms=%d",
		time.Since(forkStarted).Milliseconds(),
	)
	defer cleanupPair(t, client, pair)

	type readyResult struct {
		role      string
		startedAt string
		readyMS   int64
		err       error
	}
	ready := make(chan readyResult, 2)

	go func() {
		started := time.Now()
		err := waitRunningPostgres(ctx, client.primary, pair.Baseline)
		var startedAt string
		if err == nil {
			startedAt, err = postgresContainerStartedAtWithProvider(
				ctx,
				client.primary,
				pair.Baseline,
			)
		}
		ready <- readyResult{
			role:      "baseline",
			startedAt: startedAt,
			readyMS:   time.Since(started).Milliseconds(),
			err:       err,
		}
	}()
	go func() {
		started := time.Now()
		err := waitRunningPostgres(ctx, client.secondary, pair.Candidate)
		var startedAt string
		if err == nil {
			startedAt, err = postgresContainerStartedAtWithProvider(
				ctx,
				client.secondary,
				pair.Candidate,
			)
		}
		ready <- readyResult{
			role:      "candidate",
			startedAt: startedAt,
			readyMS:   time.Since(started).Milliseconds(),
			err:       err,
		}
	}()

	for range 2 {
		result := <-ready
		if result.err != nil {
			t.Fatalf("%s inherited PostgreSQL not ready: %v", result.role, result.err)
		}
		t.Logf(
			"postgres.%s_inherited_ready_ms=%d",
			result.role,
			result.readyMS,
		)
		if result.startedAt != parentStartedAt {
			t.Fatalf(
				"%s container StartedAt = %q, parent = %q; container appears restarted",
				result.role,
				result.startedAt,
				parentStartedAt,
			)
		}
	}

	if got := postgresProbeState(t, ctx, client, pair.Baseline); got != "golden" {
		t.Fatalf("baseline inherited state = %q, want golden", got)
	}
	if got := postgresProbeState(t, ctx, client, pair.Candidate); got != "golden" {
		t.Fatalf("candidate inherited state = %q, want golden", got)
	}

	postgresExec(t, ctx, client, pair.Baseline, `
		UPDATE rundiff_fork_probe SET value = 'baseline' WHERE id = 1;
		INSERT INTO rundiff_fork_events(role, seq)
		SELECT 'baseline', generate_series(1, 64);
		CHECKPOINT;
	`)
	postgresExec(t, ctx, client, pair.Candidate, `
		UPDATE rundiff_fork_probe SET value = 'candidate' WHERE id = 1;
		INSERT INTO rundiff_fork_events(role, seq)
		SELECT 'candidate', generate_series(1, 64);
		CHECKPOINT;
	`)

	assertPostgresWorld(t, ctx, client, pair.Baseline, "baseline", "baseline")
	assertPostgresWorld(t, ctx, client, pair.Candidate, "candidate", "candidate")
	assertPostgresWorld(t, ctx, client, parent, "golden", "")

	restartStarted := time.Now()
	postgresRestart(t, ctx, client, pair.Baseline)
	t.Logf(
		"postgres.baseline_restart_ready_ms=%d",
		time.Since(restartStarted).Milliseconds(),
	)
	restartStarted = time.Now()
	postgresRestart(t, ctx, client, pair.Candidate)
	t.Logf(
		"postgres.candidate_restart_ready_ms=%d",
		time.Since(restartStarted).Milliseconds(),
	)

	assertPostgresWorld(t, ctx, client, pair.Baseline, "baseline", "baseline")
	assertPostgresWorld(t, ctx, client, pair.Candidate, "candidate", "candidate")
	assertPostgresWorld(t, ctx, client, parent, "golden", "")

	t.Log("postgres.running_fork_isolation=ok")
	t.Log("postgres.running_fork_restart_durability=ok")
}

func postgresContainerStartedAt(
	t *testing.T,
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
) string {
	t.Helper()
	value, err := postgresContainerStartedAtWithProvider(ctx, provider, machine)
	if err != nil {
		t.Fatalf("read PostgreSQL container StartedAt on %q: %v", machine.Name, err)
	}
	return value
}

func postgresContainerStartedAtWithProvider(
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
) (string, error) {
	result, err := execBoxdOK(ctx, provider, machine, []string{
		"bash", "-lc",
		`docker inspect -f '{{.State.StartedAt}}' rundiff-postgres 2>/dev/null || sudo docker inspect -f '{{.State.StartedAt}}' rundiff-postgres`,
	})
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(result.Stdout), nil
}

func waitRunningPostgres(
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
) error {
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	for {
		result, err := provider.Exec(ctx, machine, []string{
			"bash", "-lc",
			`if docker info >/dev/null 2>&1; then d=docker; else d='sudo docker'; fi; $d exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >/dev/null`,
		})
		if err == nil && result.ExitCode == 0 {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			if err != nil {
				return err
			}
			return fmt.Errorf(
				"PostgreSQL on %q not ready, exit=%d stderr=%s",
				machine.Name,
				result.ExitCode,
				strings.TrimSpace(result.Stderr),
			)
		case <-ticker.C:
		}
	}
}

func postgresProbeState(
	t *testing.T,
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
) string {
	t.Helper()
	return strings.TrimSpace(postgresQuery(
		t,
		ctx,
		provider,
		machine,
		"SELECT value FROM rundiff_fork_probe WHERE id = 1;",
	))
}

func postgresExec(
	t *testing.T,
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
	sql string,
) {
	t.Helper()
	result, err := execBoxdOK(ctx, provider, machine, []string{
		"bash", "-lc", `sql="$1"; if docker info >/dev/null 2>&1; then d=docker; else d='sudo docker'; fi; printf '%s\n' "$sql" | $d exec -i rundiff-postgres psql -v ON_ERROR_STOP=1 -U postgres -d rundiff_bridge >/dev/null`,
		"rundiff-postgres-sql", sql,
	})
	if err != nil {
		t.Fatalf("execute PostgreSQL SQL on %q: %v: %s", machine.Name, err, result.Stderr)
	}
}

func postgresQuery(
	t *testing.T,
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
	sql string,
) string {
	t.Helper()
	result, err := execBoxdOK(ctx, provider, machine, []string{
		"bash", "-lc", `sql="$1"; if docker info >/dev/null 2>&1; then d=docker; else d='sudo docker'; fi; $d exec rundiff-postgres psql -v ON_ERROR_STOP=1 -Atq -U postgres -d rundiff_bridge -c "$sql"`,
		"rundiff-postgres-query", sql,
	})
	if err != nil {
		t.Fatalf("query PostgreSQL on %q: %v", machine.Name, err)
	}
	return result.Stdout
}

func assertPostgresWorld(
	t *testing.T,
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
	wantState string,
	wantRole string,
) {
	t.Helper()

	if got := postgresProbeState(t, ctx, provider, machine); got != wantState {
		t.Fatalf("%s probe state = %q, want %q", machine.Name, got, wantState)
	}

	baselineCount := strings.TrimSpace(postgresQuery(
		t,
		ctx,
		provider,
		machine,
		"SELECT count(*) FROM rundiff_fork_events WHERE role = 'baseline';",
	))
	candidateCount := strings.TrimSpace(postgresQuery(
		t,
		ctx,
		provider,
		machine,
		"SELECT count(*) FROM rundiff_fork_events WHERE role = 'candidate';",
	))

	switch wantRole {
	case "baseline":
		if baselineCount != "64" || candidateCount != "0" {
			t.Fatalf(
				"%s event counts baseline/candidate = %s/%s, want 64/0",
				machine.Name,
				baselineCount,
				candidateCount,
			)
		}
	case "candidate":
		if baselineCount != "0" || candidateCount != "64" {
			t.Fatalf(
				"%s event counts baseline/candidate = %s/%s, want 0/64",
				machine.Name,
				baselineCount,
				candidateCount,
			)
		}
	default:
		if baselineCount != "0" || candidateCount != "0" {
			t.Fatalf(
				"%s parent event counts baseline/candidate = %s/%s, want 0/0",
				machine.Name,
				baselineCount,
				candidateCount,
			)
		}
	}
}

func postgresRestart(
	t *testing.T,
	ctx context.Context,
	provider compute.Provider,
	machine compute.Machine,
) {
	t.Helper()
	if _, err := execBoxdOK(ctx, provider, machine, []string{
		"bash", "-lc",
		`if docker info >/dev/null 2>&1; then d=docker; else d='sudo docker'; fi; $d restart rundiff-postgres >/dev/null`,
	}); err != nil {
		t.Fatalf("restart PostgreSQL on %q: %v", machine.Name, err)
	}
	if err := waitRunningPostgres(ctx, provider, machine); err != nil {
		t.Fatalf("PostgreSQL on %q did not recover after restart: %v", machine.Name, err)
	}
}

const runningPostgresPrepareScript = `set -euo pipefail

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
  sudo systemctl start docker
fi
docker_cmd info >/dev/null

docker_cmd rm -f rundiff-postgres >/dev/null 2>&1 || true
docker_cmd pull postgres:16-alpine >/dev/null
docker_cmd run -d \
  --name rundiff-postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=rundiff_bridge \
  -p 127.0.0.1:5432:5432 \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 80); do
  if docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
docker_cmd exec rundiff-postgres pg_isready -U postgres -d rundiff_bridge >/dev/null

docker_cmd exec -i rundiff-postgres psql -v ON_ERROR_STOP=1 -U postgres -d rundiff_bridge >/dev/null <<'SQL'
CREATE TABLE rundiff_fork_probe (
  id integer PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO rundiff_fork_probe(id, value) VALUES (1, 'golden');

CREATE TABLE rundiff_fork_events (
  role text NOT NULL,
  seq integer NOT NULL,
  PRIMARY KEY (role, seq)
);
CHECKPOINT;
SQL
`
