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
go run ./apps/executor-go/cmd/rundiff-executor reference \
  --request /tmp/request.json \
  --result /tmp/result.json \
  --journal /tmp/resource-journal.jsonl \
  --cwd . \
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
