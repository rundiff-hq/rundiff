# Implementation Plan 0007: Go Executor Vertical Slice 5

## Goal

Move the typed Rails `db:prepare` subject-state boundary from the Ruby lifecycle into the managed Go executor.

This is intentionally named `subject_prepare` rather than `prepare`: the Go executor already uses `prepare` for workspace allocation. Keeping these concepts separate prevents workspace lifecycle and customer application state from collapsing into one phase.

## Execution split

~~~text
Go
  workspace prepare
  clone
  bootstrap
  subject_prepare
    rails.db_prepare
      ├─ PostgreSQL isolated DB URLs
      └─ SQLite isolated DB file
    ↓
prepared runtime_env + subject_env
    ↓
Ruby reference
  setup-plan discovery
  services
  readiness
  capture
    ↓
Go
  collect
  teardown
~~~

## Environment envelopes

Bootstrap and subject-state environment remain separate:

~~~text
RUNDIFF_PREPARED_BASELINE_RUNTIME_ENV_JSON
RUNDIFF_PREPARED_CANDIDATE_RUNTIME_ENV_JSON

RUNDIFF_PREPARED_BASELINE_SUBJECT_ENV_JSON
RUNDIFF_PREPARED_CANDIDATE_SUBJECT_ENV_JSON
~~~

The first pair describes dependency/runtime setup. The second pair describes the fully prepared Rails subject state used for capture.

This separation lets a later slice replace Ruby discovery/services without reopening Bootstrap or DB preparation.

## PostgreSQL parity

Go mirrors the current Ruby RailsPostgresEnvironment contract:

- `RAILS_ENV=test`;
- role-isolated `DATABASE_URL`;
- role-isolated `SOLID_QUEUE_DATABASE_URL`;
- Solid Queue transport and diagnostics flags;
- `bin/rails db:prepare --trace`.

The PostgreSQL server base URL comes from `RUNDIFF_LOCAL_POSTGRES_URL`, matching the existing production bridge.

## SQLite parity

Go mirrors RailsSqliteEnvironment:

- role-isolated SQLite path under the subject worktree;
- stale DB / WAL / SHM files removed before preparation;
- `ruby bin/rails db:prepare --trace`;
- test Active Job transport settings;
- host `DATABASE_URL` and `SOLID_QUEUE_DATABASE_URL` are not forwarded.

## Persistence detection

VS5 mirrors the existing Ruby discovery policy for the supported Rails path:

1. inspect explicit adapters in `config/database.yml`;
2. reject unsupported or ambiguous adapters;
3. fall back to Gemfile / Gemfile.lock evidence for `pg` or `sqlite3`.

No new public configuration is introduced.

## Ruby compatibility path

When no Go-prepared subject environment is present, Ruby continues to call `environment.prepare` exactly as before.

When a prepared subject environment is present, Ruby:

- resolves the environment object for capabilities / cleanup;
- does not call `environment.prepare`;
- uses the supplied subject env for services and capture;
- still performs cleanup.

## Measurement

New Go phase metric:

~~~text
implementation=go
phase=subject_prepare
role=base|candidate
duration_ms=...
~~~

Legacy Ruby comparison remains:

~~~text
implementation=ruby
phase=environment_prepare
role=base|candidate
~~~

The paired benchmark enables workspace + bootstrap + subject preparation in Go mode.

## Acceptance

- PostgreSQL and SQLite preparation have typed Go tests;
- base/candidate state is isolated;
- bootstrap env survives into subject env;
- Ruby skips `environment.prepare` when Go prepared state;
- role-specific subject env reaches the reference process;
- Go records `subject_prepare` metrics;
- production exact-attempt bridge remains ALLOW;
- Request v1 / Result v1 remain unchanged.
