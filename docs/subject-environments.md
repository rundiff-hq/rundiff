# Subject environments

RunDiff's own control plane is intentionally Rails + PostgreSQL. Customer subject portability lives at a different boundary.

A subject environment prepares the software being measured and returns the runtime environment needed to capture baseline/candidate evidence. The local GitHub runner delegates these responsibilities instead of owning database-product setup directly.

## Lifecycle orchestration

`RunDiff::Subject::Lifecycle` owns the orchestration around one exact subject worktree:

```text
discover subject contract
  -> bootstrap dependencies/toolchain
  -> prepare isolated state
  -> start subject-owned services
  -> healthcheck/readiness
  -> capture evidence
  -> stop subject-owned services
  -> cleanup isolated state
```

The phases deliberately compose existing boundaries instead of turning `Environment` into a framework-specific setup script:

- `Subject::Discovery` selects the environment implementation.
- a bootstrap adapter such as `RailsBundleBootstrap` prepares reproducible dependencies and returns runtime environment values.
- `Environment#prepare` provisions the role-specific state required for execution, including database preparation today.
- `Environment#start_services` starts any adapter-owned runtime services required by the subject.
- `Environment#healthcheck` proves those services are ready before capture begins.
- the caller performs capture inside the lifecycle session.
- `Environment#stop_services` and `Environment#cleanup` run during teardown.

The service hooks are no-ops by default, so the current in-process Rails + SQLite and Rails + PostgreSQL subjects keep their existing behavior. Future environments can own app servers, Redis, Compose services, or other dependencies without moving that orchestration into the GitHub runner.

Teardown is an invariant. Once an environment has been resolved, `cleanup` runs even when state preparation, service startup, readiness, or capture fails. If service startup was attempted, `stop_services` runs before cleanup. Baseline and candidate lifecycle sessions execute sequentially so subject-owned ports and service state cannot leak across the A/B boundary.

The environment-level interface is:

```text
prepare(root:, execution:, role:)
env_for(root:, execution:, role:)
start_services(root:, execution:, role:, env:)
healthcheck(root:, execution:, role:, env:)
stop_services(root:, execution:, role:, env:)
cleanup(root:, execution:, role:)
```

`env_for` exposes the adapter environment without mutating subject state. The other methods participate in lifecycle orchestration as described above.

## Capability contract

Subject environments also declare the execution capabilities they actually provide. The declarations are namespaced strings, for example:

```text
framework.rails
persistence.postgresql
persistence.sqlite
queue.solid_queue
queue.active_job_test_adapter
telemetry.subject_owned_rails
runtime.local_process
state.isolated_comparable
evidence.sql_queries
evidence.background_jobs
```

The namespaces represent composition dimensions rather than a monolithic adapter taxonomy:

```text
Subject environment
  framework.*
  persistence.*
  queue.*
  telemetry.*
  runtime.*
  state.*
  evidence.*
```

`Environment#capability?` checks an exact capability and `Environment#capabilities_for` queries one namespace.

These declarations are execution-planning and discovery metadata inside the subject boundary. They are **not** fields in `RunDiff::Executor::Request` or `RunDiff::Executor::Result`, and they are not a promise that today's capability identifiers are a stable public wire protocol.

The important semantic guarantee is `state.isolated_comparable`: baseline and candidate receive state that can be compared safely. How that property is achieved belongs to the environment implementation, not the executor contract.

Capabilities describe what an adapter can actually prove. Unsupported signals must stay absent or unavailable; adapters must never advertise or synthesize evidence merely to make two engines look alike.

## Rails + PostgreSQL subjects

`RunDiff::Subject::RailsPostgresEnvironment` preserves RunDiff's existing dogfood behavior and declares:

```text
framework.rails
persistence.postgresql
queue.solid_queue
telemetry.subject_owned_rails
runtime.local_process
state.isolated_comparable
evidence.sql_queries
evidence.background_jobs
```

Its state isolation is:

```text
baseline  -> isolated PostgreSQL primary + queue databases
candidate -> isolated PostgreSQL primary + queue databases
```

`RUNDIFF_LOCAL_POSTGRES_URL` is therefore an implementation detail of that subject environment. It is not part of `RunDiff::Executor::Request`, `RunDiff::Executor::Result`, or the generic customer execution contract.

## Rails + SQLite subjects

`RunDiff::Subject::RailsSqliteEnvironment` proves that customer persistence does not inherit the control plane's PostgreSQL requirement and declares:

```text
framework.rails
persistence.sqlite
queue.active_job_test_adapter
telemetry.subject_owned_rails
runtime.local_process
state.isolated_comparable
evidence.sql_queries
evidence.background_jobs
```

It prepares one SQLite file per execution role:

```text
baseline  -> ..._base.sqlite3
candidate -> ..._candidate.sqlite3
```

The adapter removes stale database/WAL/SHM files before preparation and cleans them after execution. The built-in proof uses Active Job's test adapter, so it does not synthesize a second queue database just to imitate the PostgreSQL dogfood environment.

The SQLite database path is passed through the adapter-private `RUNDIFF_SQLITE_DATABASE` environment variable. No `RUNDIFF_LOCAL_POSTGRES_URL`, PostgreSQL URL, or database-product field is added to the portable executor request/result schemas.

`script/prove_rails_sqlite_subject.rb` builds a disposable Rails + SQLite Git subject, injects the same RunDiff Rails instrumentation, creates baseline and candidate commits, and executes them through:

```text
RunDiff::Executor::Request v1
  -> LocalAdapter
  -> LocalPullRequestRunner
  -> Subject::Lifecycle
  -> RailsSqliteEnvironment
  -> script/rundiff_capture_subject.rb
  -> ExecutionReducer / ExecutionPair
  -> RunDiff::Executor::Result v1
```

The candidate deliberately increases database query behavior so the proof returns real SQLite query evidence and a `DATABASE_QUERY_REGRESSION` through the same Behavioral Diff contract used for PostgreSQL dogfood.

This is customer-subject adapter coverage. It does not make the RunDiff service itself SQLite-compatible; RunDiff's durable control plane remains PostgreSQL-only by design.

## Portable and native evidence

The current portable database semantic is the existing `sql_queries` signal used by Behavioral Diff. Both PostgreSQL and SQLite proofs can produce it without requiring the diff layer to know the database engine.

Future adapters may add richer portable semantics and native evidence side by side, for example query duration or transaction counts as portable evidence and engine-specific explain/scan/lock evidence where supported. Native evidence should be preserved rather than flattened into invented cross-engine equivalence.

Do not build framework/database/queue adapter matrices speculatively. Add capability implementations when a real customer stack requires them. Rails + SQLite is the first portability proof; subsequent adapters can compose the same namespaces without changing the portable executor wire contract.

See #43, #44, #54, #78, and #82.
