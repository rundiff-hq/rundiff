# Implementation Plan 0003: Go Executor Vertical Slice 1

## Goal

Create the first standalone Go executor binary without changing the frozen Executor Request v1 / Result v1 contract or prematurely replacing the proven Ruby runtime.

The slice must prove that Go can own protocol parsing, explicit lifecycle supervision, cancellation timeout, resource journaling, process supervision, and portable result production while the Ruby executor remains the behavioral oracle.

## Boundary

~~~text
Cloudflare Control Plane
        |
        | Request v1
        v
Go Executor VS1
  protocol validator
  lifecycle supervisor
  Resource Journal
        |
        v
reference process adapter
        |
        v
Ruby reference executor
        |
        | Result v1
        v
Go result validator
        |
        v
Control Plane
~~~

VS1 is a strangler seam, not a permanent Ruby dependency.

## Package layout

~~~text
apps/executor-go/
  cmd/rundiff-executor/
  internal/
    executor/
    journal/
    protocol/
    runner/
~~~

`internal/protocol` is transport-only. It must not import GitHub, Rails, Cloudflare, or policy code.

`internal/executor` owns lifecycle sequencing.

`internal/journal` owns append-only cleanup/recovery records.

`internal/runner` owns the temporary reference-process compatibility adapter.

## Accepted lifecycle model

RFC 0009 phase names are declared now:

~~~text
Prepare
Clone
Bootstrap
Build
Start
Ready
Scenario
Collect
Teardown
~~~

VS1 actively records only the phases it actually owns: Prepare, Scenario, Collect, and Teardown. It must not emit fictional completion for Clone/Bootstrap/Build/Start/Ready before Go owns those operations.

## Resource Journal

VS1 writes append-only JSONL with at least:

- monotonically increasing sequence;
- timestamp;
- execution ID;
- attempt number;
- event kind;
- phase when applicable;
- resource kind and identity when applicable.

The journal must never contain GitHub App credentials, repository capabilities, or environment dumps.

## Cancellation

VS1 uses Go context timeout/cancellation around the reference child process.

This is intentionally weaker than the managed-host target: `exec.CommandContext` reliably owns the direct child but does not yet prove deterministic descendant cleanup. Process-group/cgroup termination is the next host-runtime slice and remains an explicit acceptance item rather than an implied guarantee.

## Protocol compatibility

The Go implementation must consume the canonical files in `protocol/executor/v1`.

Acceptance requires:

- request golden fixture accepted;
- ALLOW result fixture accepted;
- BLOCK result fixture accepted;
- failed result fixture accepted;
- additive unknown fields tolerated by readers;
- produced failed results validate as Result v1.

No Go-only field may be added to Request v1 or Result v1.

## CI

The cheap quality gate must run before expensive topology proofs:

~~~text
gofmt check
go test ./...
go vet ./...
CGO_ENABLED=0 go build
linux/amd64 build
linux/arm64 build
~~~

## Acceptance

VS1 is complete when:

1. the standalone binary validates the shared golden protocol fixtures;
2. a supervised child can consume Request v1 and return Result v1;
3. resource creation/removal is journaled;
4. invalid/missing child result becomes failed Result v1, not an unhandled crash;
5. the binary builds with `CGO_ENABLED=0` for Linux amd64 and arm64;
6. existing Ruby/Cloudflare tests remain green;
7. no GitHub App secret or provider-specific authentication enters the Go protocol package.

## Next slice

VS2 connects the Go executor to exact control-plane assignment:

~~~text
execution_id + attempt_number
  -> acquire exact attempt
  -> heartbeat/progress
  -> cancellation
  -> Result v1
~~~

Only after that boundary is proven should Go begin replacing the reference runner with native repository/subject lifecycle phases.
