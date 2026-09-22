# RunDiff Go Executor

This directory contains the standalone managed-executor implementation direction from RFC 0009.

## VS1 scope

Vertical Slice 1 intentionally proves the boundary before reimplementing the Rails subject runtime:

~~~text
Request v1
  -> Go protocol validation
  -> Go lifecycle supervisor
  -> Resource Journal JSONL
  -> reference process adapter
  -> Result v1 validation
  -> Result v1
~~~

The reference process adapter can supervise the existing Ruby reference executor without putting Ruby types or Rails state inside the Go protocol package.

Example from the repository root:

~~~bash
(
  cd apps/executor-go
  CGO_ENABLED=0 go build -o /tmp/rundiff-executor ./cmd/rundiff-executor
)

/tmp/rundiff-executor reference \
  --request /tmp/request.json \
  --result /tmp/result.json \
  --journal /tmp/resource-journal.jsonl \
  --cwd "$PWD" \
  -- bundle exec ruby script/run_cloudflare_executor_bridge.rb
~~~

The child receives the same compatibility environment used by the existing bridge:

~~~text
RUNDIFF_EXECUTOR_REQUEST_PATH
RUNDIFF_EXECUTOR_RESULT_PATH
~~~

## Current guarantees

- frozen Executor Request v1 / Result v1 are validated in Go;
- the Go tests consume the repository canonical golden fixtures;
- no cgo is required;
- process invocation uses argv, never a shell;
- execution has an explicit overall timeout;
- workspace and process resources are recorded in append-only JSONL;
- temporary workspace cleanup runs on success and failure;
- child failures are converted to portable failed Result v1;
- the Go supervisor is independent from GitHub App credentials and webhook state.

## Deliberately deferred

VS1 does **not** claim that managed host isolation is complete. The next slices add:

1. exact control-plane assignment by `execution_id + attempt_number`;
2. host heartbeat/progress and cooperative cancellation transport;
3. process-tree/cgroup termination instead of direct-child cancellation only;
4. cgroup v2 accounting and baseline/candidate child boundaries;
5. namespace isolation and controlled networking;
6. native clone/bootstrap/build/start/ready/scenario/collect providers;
7. independent sweeper reconciliation;
8. OTLP / local evidence bus.

The Ruby executor remains the behavioral oracle until Go produces equivalent evidence for the same golden scenarios.


## Phase timing and Ruby/Go comparison

Executor timing is recorded as append-only JSONL using one internal schema for both implementations:

~~~json
{"schema_version":"1","execution_id":"...","implementation":"go","phase":"clone","duration_ms":412,"outcome":"ok"}
{"schema_version":"1","execution_id":"...","implementation":"ruby","phase":"bootstrap","role":"base","duration_ms":2310,"outcome":"ok"}
~~~

The stream intentionally contains phase identity and timing only. It must not contain source, request payloads, environment values, credentials, command output, or customer evidence.

Production bridge runs write both:

~~~text
*.journal.jsonl       resource/lifecycle recovery record
*.metrics.jsonl       performance measurement stream
~~~

The metrics JSONL is the local source of truth. An OTLP exporter can consume the same events later without making network delivery part of executor correctness.

For a paired local comparison of repository preparation, run the same Request v1 twice on the same runner and alternate order between repetitions:

~~~bash
# Ruby owns prepare/clone
rundiff-executor reference \
  --request request.json \
  --result ruby-result.json \
  --metrics ruby-metrics.jsonl \
  --cwd "$PWD" \
  -- bundle exec ruby script/run_cloudflare_executor_bridge.rb

# Go owns prepare/clone; Ruby starts after exact worktrees already exist
rundiff-executor reference \
  --native-workspace \
  --request request.json \
  --result go-result.json \
  --metrics go-metrics.jsonl \
  --cwd "$PWD" \
  -- bundle exec ruby script/run_cloudflare_executor_bridge.rb
~~~

Use at least five alternating pairs and compare median and p95 for `prepare`, `clone`, and total wall time. Do not infer a language speedup from one CI run: Git fetch state, filesystem cache, Bundler cache, Postgres warmup, and runner load can dominate the result.


Summarize any number of collected runs:

~~~bash
rundiff-executor metrics-summary run-*.metrics.jsonl
~~~

Output:

~~~text
implementation  phase      role       count  median_ms  p95_ms  min_ms  max_ms
go              clone                 10     ...        ...     ...     ...
ruby            bootstrap  base       10     ...        ...     ...     ...
ruby            bootstrap  candidate  10     ...        ...     ...     ...
~~~

The GitHub Actions bridge retains the phase-metrics JSONL as a 14-day artifact so paired samples can be downloaded and summarized later.
