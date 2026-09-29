package boxd

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

func TestLivePostgresForkIsolation(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd PostgreSQL fork proof")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd PostgreSQL fork proof")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live Boxd PostgreSQL fork proof")
	}

	client := NewSDK("node", "sdkbridge/bridge.mjs")
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
	defer cancel()

	parentName := "rundiff-pg-p-" + proofID
	baselineName := "rundiff-pg-b-" + proofID
	candidateName := "rundiff-pg-c-" + proofID

	createStarted := time.Now()
	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create PostgreSQL golden parent: %v", err)
	}
	t.Logf("postgres.provider.create.parent_ready_ms=%d", time.Since(createStarted).Milliseconds())
	defer removeMachine(t, client, parent)

	prepareStarted := time.Now()
	if _, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc", postgresForkPrepareScript,
	}); err != nil {
		t.Fatalf("prepare running PostgreSQL parent: %v", err)
	}
	t.Logf("postgres.parent_prepare_ms=%d", time.Since(prepareStarted).Milliseconds())

	assertPostgresRows(t, ctx, client, parent, "seed")

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
	t.Logf("postgres.provider.fork_pair_ready_ms=%d", time.Since(forkStarted).Milliseconds())
	defer cleanupPair(t, client, pair)

	assertPostgresHealthy(t, ctx, client, pair.Baseline)
	assertPostgresHealthy(t, ctx, client, pair.Candidate)
	assertPostgresHealthy(t, ctx, client, parent)

	insertPostgresRow(t, ctx, client, pair.Baseline, "baseline")
	assertPostgresRows(t, ctx, client, pair.Baseline, "baseline,seed")
	assertPostgresRows(t, ctx, client, pair.Candidate, "seed")
	assertPostgresRows(t, ctx, client, parent, "seed")

	insertPostgresRow(t, ctx, client, pair.Candidate, "candidate")
	assertPostgresRows(t, ctx, client, pair.Candidate, "candidate,seed")
	assertPostgresRows(t, ctx, client, pair.Baseline, "baseline,seed")
	assertPostgresRows(t, ctx, client, parent, "seed")

	t.Log("postgres.live_running_fork_isolation=ok")
}

func assertPostgresHealthy(
	t *testing.T,
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
) {
	t.Helper()

	result, err := execEventually(
		ctx,
		client,
		machine,
		[]string{"bash", "-lc", postgresForkHealthScript},
	)
	if err != nil {
		t.Fatalf("PostgreSQL not healthy in %q: %v", machine.Name, err)
	}
	if result.ExitCode != 0 {
		t.Fatalf("PostgreSQL health exit code in %q = %d", machine.Name, result.ExitCode)
	}
}

func insertPostgresRow(
	t *testing.T,
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	value string,
) {
	t.Helper()

	result, err := execBoxdOK(ctx, client, machine, []string{
		"bash", "-lc", postgresForkInsertScript, "rundiff-postgres-insert", value,
	})
	if err != nil {
		t.Fatalf("insert PostgreSQL row %q in %q: %v", value, machine.Name, err)
	}
	if strings.TrimSpace(result.Stdout) == "" {
		t.Fatalf("insert PostgreSQL row %q in %q produced no output", value, machine.Name)
	}
}

func assertPostgresRows(
	t *testing.T,
	ctx context.Context,
	client compute.Provider,
	machine compute.Machine,
	want string,
) {
	t.Helper()

	result, err := execBoxdOK(ctx, client, machine, []string{
		"bash", "-lc", postgresForkRowsScript,
	})
	if err != nil {
		t.Fatalf("query PostgreSQL rows in %q: %v", machine.Name, err)
	}
	if got := strings.TrimSpace(result.Stdout); got != want {
		t.Fatalf("PostgreSQL rows in %q = %q, want %q", machine.Name, got, want)
	}
}

const postgresForkPrepareScript = `set -euo pipefail

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

docker_cmd rm -f rundiff-postgres-fork >/dev/null 2>&1 || true
docker_cmd pull postgres:16-alpine >/dev/null
docker_cmd run -d \
  --name rundiff-postgres-fork \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=rundiff_fork \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 120); do
  if docker_cmd exec rundiff-postgres-fork pg_isready -U postgres -d rundiff_fork >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

docker_cmd exec rundiff-postgres-fork pg_isready -U postgres -d rundiff_fork >/dev/null
docker_cmd exec rundiff-postgres-fork psql -U postgres -d rundiff_fork -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE fork_events (name text PRIMARY KEY); INSERT INTO fork_events(name) VALUES ('seed');" \
  >/dev/null
`

const postgresForkHealthScript = `set -euo pipefail

if docker info >/dev/null 2>&1; then
  docker exec rundiff-postgres-fork pg_isready -U postgres -d rundiff_fork >/dev/null
else
  sudo docker exec rundiff-postgres-fork pg_isready -U postgres -d rundiff_fork >/dev/null
fi
`

const postgresForkInsertScript = `set -euo pipefail
value="$1"

if docker info >/dev/null 2>&1; then
  docker exec rundiff-postgres-fork psql -U postgres -d rundiff_fork -v ON_ERROR_STOP=1 -At \
    -c "INSERT INTO fork_events(name) VALUES ('$value') RETURNING name;"
else
  sudo docker exec rundiff-postgres-fork psql -U postgres -d rundiff_fork -v ON_ERROR_STOP=1 -At \
    -c "INSERT INTO fork_events(name) VALUES ('$value') RETURNING name;"
fi
`

const postgresForkRowsScript = `set -euo pipefail

if docker info >/dev/null 2>&1; then
  docker exec rundiff-postgres-fork psql -U postgres -d rundiff_fork -At \
    -c "SELECT string_agg(name, ',' ORDER BY name) FROM fork_events;"
else
  sudo docker exec rundiff-postgres-fork psql -U postgres -d rundiff_fork -At \
    -c "SELECT string_agg(name, ',' ORDER BY name) FROM fork_events;"
fi
`
