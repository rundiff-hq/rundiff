# Architecture

## Core model

A `Run` is one comparison request for one scenario and one change.

```text
Run: PR #42 / signup-create-project
├── baseline Execution: main@abc123
└── candidate Execution: pr-42@def456
```

An `Execution` is one scenario run against one subject. It may produce functional results, driver events, traces, logs, measurements, process samples, screenshots/video, native test artifacts, profiles, and side-effect records.

A scenario is durable product intent, not a framework-specific test file.

```text
scenario: user.signup.create-project
web implementation: Playwright
mobile implementation: Maestro
api implementation: HTTP/gRPC
```

## Correlation

Use separate IDs:

- `run_id` - baseline/candidate comparison
- `execution_id` - one subject execution
- `trace_id` - one distributed causal trace
- `span_id` - one operation

One execution can contain many traces.

Preferred propagation is W3C `traceparent` plus baggage such as `rundiff.execution.id`. In controlled test environments, `X-RunDiff-Execution-Id` is also acceptable.

Propagate through HTTP/gRPC, jobs, Temporal, internal services, logs/spans, and controlled emulators. Do not blindly leak internal baggage to untrusted providers.

Do not put `execution_id` on metric labels. It is high cardinality; use exemplars or execution-level aggregation.

## Storage

PostgreSQL holds product metadata. Large immutable evidence belongs in R2/S3: Playwright traces, screenshots/video, rrweb recordings, HAR, profiles, compressed logs, and mobile recordings.

## Extraction seams

Potential future packages:

- `rundiff-protocol`
- `rundiff-cli`
- `rundiff-playwright`
- `rundiff-recorder`
- `rundiff-otel`
- `rundiff-mobile`
- `rundiff-github`

Extract only when a component gains an independent runtime, language, release cadence, or external consumer.
