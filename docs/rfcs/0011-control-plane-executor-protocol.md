# RFC 0011: Control-plane/executor protocol boundary and durable causal lineage

## Status

Proposed research direction. This RFC does not accept a transport migration yet.

## Context

RunDiff already has a durable control-plane/executor boundary, an accepted Go managed-executor direction, exact-attempt leases, cancellation/supersession semantics, and OTLP as the preferred portable telemetry transport.

What remains intentionally open is the network protocol between the Rails control plane and a future long-lived managed Go Executor host.

RFC 0009 explicitly leaves heartbeat/progress protocol as future work. That protocol should be designed before implementation pressure turns the current transport into a permanent accidental contract.

## Decision summary

1. Keep RunDiff domain contracts independent from the wire protocol.
2. Treat Protobuf + ConnectRPC as the leading candidate for the managed control-plane/executor command/query surface.
3. Keep current working transports until a measured spike proves migration value.
4. Keep OTLP/OpenTelemetry as the portable telemetry/evidence transport where appropriate. Do not push bulk telemetry through the executor command API merely because both endpoints exist.
5. Preserve durable execution/lease causality independently from OpenTelemetry trace availability.
6. Do not make generated Protobuf types the RunDiff domain model.
7. Do not require HTTP/2 for operations that are naturally unary and work correctly over ordinary HTTP/1.1.
8. Introduce streaming only for a concrete requirement such as server-pushed cancellation/progress or a measured efficiency need.

## Semantic boundary

The target layering is:

~~~text
RunDiff domain
  Execution Plan
  Execution Lease
  Progress
  Cancellation
  Result / Findings
        |
        v
transport adapters
        |
        +--> current HTTP/JSON where already proven
        +--> candidate Protobuf + ConnectRPC for managed executor control

subject / sensors
        |
        +--> OTLP / local evidence bus
        |
        v
executor evidence normalizer
~~~

The control protocol and evidence protocol solve different problems.

A command such as "lease execution" or "cancel attempt" needs fencing, authentication, deadlines, and typed outcomes.

Telemetry needs high-volume signal transport, batching, provenance, and evidence semantics.

They may share identity but should not be collapsed into one protocol.

## Candidate managed-executor operations

Names below are illustrative, not stable API:

~~~text
RegisterExecutor
Heartbeat
LeaseExecution
ReportProgress
CancelExecution
CompleteExecution
ReportCleanup
~~~

The actual protocol may preserve the existing pull/lease/report direction rather than creating a publicly reachable arbitrary execution RPC.

The security invariant from the existing executor design remains: customer code execution must be authorized by the control plane and fenced to an exact attempt/lease.

## Why ConnectRPC is now worth a focused spike

Hatchet provides useful 2026 implementation evidence for a closely related developer-infrastructure workload:

- PR #4987 migrated the engine protocol from a gRPC server to ConnectRPC while preserving compatibility with existing gRPC clients and targeting serverless/frontend compatibility.
  https://github.com/hatchet-dev/hatchet/pull/4987
- PR #5016 added a configurable TypeScript transport and ConnectRPC unary RPCs that can operate over HTTP/1.1 or HTTP/2, motivated by edge/serverless runtimes.
  https://github.com/hatchet-dev/hatchet/pull/5016
- Hatchet's server explicitly supports HTTP/1.1 for fetch-based Connect callers while retaining HTTP/2 where gRPC/streaming needs it.
  https://github.com/hatchet-dev/hatchet/blob/d116ba72b0383bb74b246d8d15f0189f7f8c16d6/internal/services/grpc/server.go

This is evidence that Connect can preserve Protobuf contracts without forcing every caller into classic gRPC transport assumptions.

It is not evidence that RunDiff should replace a working transport before the managed host path needs it.

## Durable causal lineage

RunDiff must remain explainable when traces are sampled, absent, or split by long waits/retries.

Hatchet separately added source workflow-run and step-run metadata to events so cross-workflow trace linking survives even without its OTel instrumentor. The relevant lesson is that workflow/execution lineage must not depend on a continuous trace.

Reference:
https://github.com/hatchet-dev/hatchet/blob/d116ba72b0383bb74b246d8d15f0189f7f8c16d6/sdks/typescript/CHANGELOG.md

For a managed RunDiff attempt, preserve explicit durable identity such as:

~~~text
review_id
execution_id
attempt
lease_id
message_or_event_id
causation_id

trace_id
span_id
~~~

Rules:

- review/execution/attempt/lease identity is product/runtime truth.
- causation identifies the immediate predecessor when a discrete command/event relationship exists.
- trace_id and span_id remain technical execution context and may be absent.
- a later retry or resumed phase may start a new trace while remaining part of the same RunDiff execution conversation.
- W3C Trace Context and OpenTelemetry Span Links remain the standard technical tracing mechanisms.
- high-cardinality execution identity must not become ordinary metrics dimensions.

## Authentication and trust

A future Connect transport must preserve existing authority boundaries:

- the executor never receives the GitHub App private key or webhook secret;
- repository access remains short-lived and repository-scoped;
- each leased attempt is fenced by execution/attempt/lease identity;
- late completion from a cancelled or superseded attempt cannot become authoritative;
- message size, decompression, timeout, and resource-exhaustion limits are explicit;
- transport authentication is separate from customer-code credentials.

## Required spike

Before adopting ConnectRPC, compare at least:

1. the current proven HTTP/JSON approach;
2. Protobuf + Connect unary RPC over HTTP/1.1;
3. Connect over HTTP/2 where streaming is actually required.

Measure:

### Contract quality

- Go and Rails integration ergonomics;
- generated client/server compatibility;
- schema evolution and unknown-field behavior;
- typed error/detail usefulness;
- domain isolation from generated types.

### Runtime

- payload size;
- encode/decode cost;
- latency;
- cancellation/deadline propagation;
- connection reuse;
- compression behavior;
- long-lived stream failure/reconnect behavior if streaming is tested.

### Operability

- local debugging;
- request/response inspection;
- production logs;
- OpenTelemetry instrumentation;
- reverse proxy/CDN behavior;
- incident diagnostics.

### Deployment compatibility

- managed RunDiff hosts;
- Cloudflare-facing control plane paths where relevant;
- GitHub Actions/external dispatch bridges;
- future BYOC/private-network executor hosts.

## Migration strategy

If the spike proves value:

1. freeze semantic acceptance tests for the existing control boundary;
2. define versioned Protobuf messages around the same domain semantics;
3. run the same lease/cancellation/progress/result tests against both adapters;
4. migrate one narrow managed-host path first;
5. preserve mixed-version behavior only for as long as fleet reality requires;
6. remove obsolete transport code rather than supporting every protocol indefinitely.

If no external fleet exists yet, a clean cut may be cheaper than a long dual-stack period.

## Non-goals

This RFC does not:

- replace OTLP with ConnectRPC;
- require gRPC compatibility as a product feature;
- turn the managed executor protocol into a public customer API;
- change Execution Plan or Result semantics merely to fit generated types;
- introduce streaming without a demonstrated use case;
- make one trace span cover a sleeping/queued execution;
- change the accepted Go managed-executor direction.

## Relationship to existing RFCs

- RFC 0004 defines compute, placement, and evidence strategy.
- RFC 0006 defines portable execution and multi-source evidence.
- RFC 0009 defines the managed Go Executor host runtime.
- This RFC narrows the future network transport and durable causal-identity boundary between the control plane and that executor.

## Open questions

- Does cancellation benefit enough from server streaming to justify a long-lived channel, or is lease polling sufficient?
- Should progress share the command channel or use a separate append-only event/report surface?
- Does the Rails control plane need generated Protobuf types directly, or should a small gateway isolate transport code?
- Which exact identity becomes the portfolio-level correlation_id projection for RunDiff without duplicating execution identity?
- Is gRPC compatibility useful for any RunDiff consumer, or is Connect-only interoperability sufficient?
