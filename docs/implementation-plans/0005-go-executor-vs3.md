# Implementation Plan 0005: Go Executor Vertical Slice 3

## Goal

Move repository workspace ownership for the existing same-repository GitHub path from Ruby into Go while retaining the Ruby behavioral oracle for Bootstrap through Collect.

At the same boundary, establish paired Ruby/Go phase timing so migration performance can be measured rather than guessed.

## Execution split

~~~text
Go
  Prepare
  Clone
  |
  v
prepared baseline/candidate worktrees
  |
  v
Ruby reference
  Bootstrap
  Build / environment
  Start / Ready
  Scenario
  Collect
  |
  v
Go
  Result validation
  Teardown worktrees
~~~

The Ruby runner treats Go-prepared worktrees as borrowed resources. It may validate their exact HEAD revisions but must not fetch, recreate, or remove them.

## Metrics

Both Ruby and Go emit the same internal JSONL timing envelope:

~~~text
schema_version
timestamp
execution_id
attempt_number where available
implementation
phase
role where applicable
duration_ms
outcome
error_class when applicable
~~~

This is operational telemetry, not a public Result contract.

The Resource Journal remains cleanup/recovery authority. Phase metrics remain performance evidence. They are separate by design.

## Benchmark method

A useful Ruby-vs-Go comparison must be paired:

1. same GitHub runner class / machine;
2. same repository and exact baseline/candidate SHAs;
3. same runtime and dependency caches;
4. alternate Ruby-first and Go-first ordering;
5. at least five pairs;
6. report median and p95, not only minimum;
7. compare both the migrated phase and total wall clock.

Expected caveat: both implementations still shell out to the same `git` binary, so Clone may not become dramatically faster. The larger reasons for Go ownership are cancellation, cleanup, resource attribution, process-tree control, and removing a Ruby/Rails dependency from the host agent. Timing data will show whether there is also a material latency win.

## OTLP direction

Do not couple correctness to an OTel collector in VS3.

The JSONL metric envelope is the local source of truth. A later exporter maps it to OTel metrics/spans:

~~~text
rundiff.executor.phase.duration
attributes:
  implementation
  phase
  role
  outcome
  execution_id (high-cardinality trace/log attribute, not necessarily metric dimension)
~~~

Collector/export failure must never fail workload execution.

## Acceptance

- Go creates exact baseline/candidate Git worktrees;
- Go journals workspace/worktree creation and removal;
- Ruby reuses prepared worktrees and skips fetch/add/remove;
- prepared worktree HEADs are verified before Ruby execution;
- Go teardown runs on success/failure;
- Go emits `prepare` and `clone` duration metrics;
- Ruby stage timer emits compatible JSONL metrics;
- production bridge surfaces timing events;
- Request v1 / Result v1 remain unchanged;
- VS2 exact lease/heartbeat lifecycle remains unchanged.
