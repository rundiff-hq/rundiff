# RFC 0009: Managed Go Executor host runtime

## Status

Accepted implementation direction. Detailed isolation choices remain incremental and must be proven experimentally.

## Context

RunDiff currently has a proven portable control-plane -> executor-service boundary implemented in the Rails codebase.

The managed execution direction goes further.

RunDiff needs a dedicated execution supervisor that can reliably run arbitrary customer workloads, enforce lifecycle/cancellation, collect host/process evidence, and eventually support controlled microVM isolation.

The managed Executor is not a generic CI shell runner and is not defined by Docker.

Its primary job is supervision of foreign processes and execution environments.

## Decision summary

1. Implement the managed RunDiff Executor in Go.
2. Do not use cgo in the executor.
3. Keep sensors/low-level collectors out of process behind language-neutral evidence contracts.
4. Prefer a host-level executor agent when RunDiff controls the host and needs cgroups, namespaces, KVM, eBPF, block/network visibility, or reliable process-tree termination.
5. Model execution as explicit phases with durable progress and cleanup semantics.
6. Use cgroup v2 as the primary Linux resource/accounting boundary on controlled Linux hosts.
7. Baseline and candidate should have separate child resource boundaries while remaining under the same review/lease envelope where paired comparison is required.
8. Use Linux namespaces and capability restriction to minimize host exposure.
9. Track created resources in an append-only Resource Journal so cleanup can be retried after process crashes.
10. Cleanup is two-phase: normal in-process teardown plus an external/independent sweeper for leaked resources.
11. Cancellation first uses cooperative signals where supported, then escalates to deterministic process/cgroup termination.
12. Superseded reviews must stop consuming managed compute rather than merely relying on stale-result rejection.
13. OTLP is the preferred portable telemetry transport, with a local evidence bus for executor/sensor coordination where useful.
14. The executor executes an already-resolved Execution Plan. It does not own Placement Engine policy or merge decisions.
15. Firecracker is an optional isolation backend for controlled RunDiff Fleet, not the executor itself and not a determinism guarantee.

## Responsibilities

The managed Executor owns:

- execution environment acquisition/use;
- exact revision preparation;
- bootstrap/build;
- subject lifecycle;
- process/container/microVM supervision;
- resource limits;
- readiness;
- scenario execution;
- evidence collection;
- cancellation;
- cleanup;
- progress/heartbeat;
- portable result production.

It does not own:

- GitHub webhook authentication;
- billing/product entitlement policy;
- provider selection;
- final merge recommendation policy;
- stale PR identity authority;
- long-term source-code storage;
- GitHub publication.

Those remain control-plane responsibilities.

## Lifecycle state machine

Target execution phases:

~~~text
Prepare
  -> Clone
  -> Bootstrap
  -> Build
  -> Start
  -> Ready
  -> Scenario
  -> Collect
  -> Teardown
~~~

Each phase should:

- have a bounded timeout where practical;
- emit progress;
- record resources created;
- honor cancellation;
- classify failures;
- be safe to retry only where semantics allow it.

A future protocol may expose phase progress to the control plane without making phase names a permanent public API.

## Execution envelope

On a controlled Linux host:

~~~text
review lease
  |
  +-- cgroup: rundiff/<review>
       |
       +-- baseline
       |
       +-- candidate
       |
       +-- sensors / helper processes
~~~

The exact hierarchy is implementation-specific, but the semantic goals are:

- account aggregate review compute;
- isolate baseline and candidate resource usage;
- make process-tree cleanup deterministic;
- attribute CPU/memory/I/O correctly;
- prevent one side from silently sharing writable state with the other;
- support paired Performance comparison on the same host/lease.

## Linux isolation target

For the controlled-fleet path, investigate and progressively enforce:

- cgroup v2;
- PID namespace with a proper init/reaper;
- mount namespace;
- network namespace;
- user/UID isolation;
- read-only root filesystem where compatible;
- explicit writable workspace/state mounts;
- dropped Linux capabilities;
- seccomp profile;
- no implicit host networking;
- bounded filesystem/disk usage;
- explicit egress policy where supported.

These are target controls, not a claim that every external Execution Plan can provide them.

Provider capability detection determines which controls are available.

## Host network boundary

Customer workloads should not inherit the host network by default on controlled RunDiff infrastructure.

A future network layer may provide:

- isolated namespace;
- controlled egress;
- service-to-service network;
- local database/cache topology;
- network evidence;
- deterministic port allocation;
- optional inbound scenario proxy.

External providers may impose their own network model; that model must be represented in Execution Plan capability/provenance.

## Resource Journal

Every resource created by an execution should be journaled before or immediately after creation.

Preferred implementation direction: append-only JSONL.

Illustrative entries:

~~~json
{"kind":"workspace","path":"/var/lib/rundiff/executions/abc"}
{"kind":"cgroup","path":"/sys/fs/cgroup/rundiff/abc"}
{"kind":"process","pid":12345}
{"kind":"network_namespace","name":"rundiff-abc"}
{"kind":"microvm","id":"vm-abc"}
{"kind":"artifact_temp","path":"/var/lib/rundiff/tmp/abc"}
~~~

The exact schema is not yet a stable protocol.

The journal exists for cleanup/recovery, not as the product evidence model.

## Two-phase cleanup

### Phase 1: in-process teardown

Normal execution uses structured cleanup:

~~~text
stop scenario driver
stop subject
stop dependencies
stop sensors
kill remaining descendants
unmount/remove runtime resources
remove workspace
close cgroups/namespaces
seal/upload artifacts
~~~

Cleanup runs even after failed Start, Ready, Scenario, or Collect phases where possible.

### Phase 2: sweeper

An independent sweeper scans for resources whose owning lease is terminal/expired or whose executor process disappeared.

It can reconcile:

- abandoned workspaces;
- cgroups;
- namespaces;
- containers;
- microVMs;
- temp artifacts;
- stale process trees.

The sweeper must use lease/resource identity and fail safely. It must not delete resources for a current live execution.

## Cancellation

Cancellation has two layers.

### Durable authority

The Rails control plane remains the authority that marks an exact attempt cancelled or superseded.

### Host enforcement

The Go executor enforces cancellation locally.

Target sequence:

~~~text
cancellation received
  -> mark local attempt cancelling
  -> cooperative signal/API
  -> short grace period
  -> terminate remaining process tree/cgroup
  -> stop containers/microVMs
  -> cleanup
  -> report cancelled
~~~

A superseded candidate should follow the same resource termination path.

Late evidence from a cancelled/superseded attempt cannot become authoritative.

## Failure taxonomy

Executor failures should distinguish at least:

- WORKLOAD_FAILURE;
- PROVIDER_INFRA_FAILURE;
- CAPABILITY_MISMATCH;
- BOOTSTRAP_FAILURE;
- BUILD_FAILURE;
- READY_TIMEOUT;
- EXECUTION_TIMEOUT;
- OOM;
- DISK_EXHAUSTED;
- CANCELLED;
- SUPERSEDED;
- SENSOR_FAILURE;
- CLEANUP_FAILURE.

The exact reason-code contract requires separate versioning.

Placement learning must not interpret customer-code failures as evidence that a provider is unreliable.

## Evidence architecture

Evidence can arrive from:

- framework-native adapters;
- OpenTelemetry;
- process/cgroup sampling;
- network probes;
- eBPF sensors;
- driver artifacts;
- runtime logs.

Preferred direction:

~~~text
subject / sensors
      |
      +--> local evidence bus
      |
      +--> OTLP where appropriate
                |
                v
        executor normalizer
                |
                v
        evidence/artifact output
~~~

A Unix domain socket is the preferred initial local IPC candidate for executor/sensor event transport on Linux because it is local, efficient, and independent of customer network configuration.

The exact evidence-bus framing is not yet a public contract.

## OpenTelemetry Collector

A controlled execution environment may run an OpenTelemetry Collector as an executor-managed component.

Benefits:

- language-neutral OTLP ingestion;
- local buffering;
- consistent processors/export;
- subject does not need credentials for the RunDiff control plane;
- evidence can be correlated with execution identity locally.

The Collector is an evidence component, not the RunDiff domain model.

## Sensors

Sensors are separate components.

Examples:

- eBPF collector;
- process sampler;
- network collector;
- runtime-specific adapter.

Rules:

- do not link them into the supervisor through cgo;
- communicate over explicit IPC/protocol boundaries;
- version evidence envelopes;
- sensor failure should be attributable and should not necessarily crash Standard evidence execution;
- Deep evidence must fail or degrade explicitly according to requested contract, never silently pretend full evidence exists.

Go is preferred first where practical.

Rust is acceptable for a measured low-level requirement, especially sensor-side, without changing the executor contract.

## Paired Performance execution

For Performance Evidence, baseline and candidate should run under one comparable execution lease where possible.

Target:

~~~text
acquire host/environment
  -> calibrate
  -> baseline child cgroup
  -> candidate child cgroup
  -> optional interleaving/repetition
  -> compare
  -> teardown
~~~

The executor must keep comparable:

- CPU allocation;
- memory allocation;
- worker count;
- shard count;
- runtime version;
- database/service topology;
- relevant cache policy;
- test ordering/seed where required.

See RFC 0004 for confidence gating and parallelism.

## Firecracker path

On RunDiff-controlled hosts:

~~~text
host
  -> Go Executor
       -> Firecracker microVM
            -> workload runtime
                 -> app/services/tests
~~~

Firecracker is considered for:

- tenant isolation;
- disposable state;
- fast lifecycle;
- resource boundaries;
- clean snapshots/forks where safe.

It does not make the physical host noise-free.

The executor must be able to use other runtimes when Execution Plan selects them.

## External provider path

When the executor runs inside GitHub Actions, Buildkite, Cloudflare, E2B, Namespace, or another external system, some host-level controls may be unavailable.

In that case:

- Execution Plan records provenance/capabilities;
- executor uses the strongest available boundary;
- unsupported Deep capabilities are not claimed;
- Performance confidence reflects measured environment stability;
- cleanup uses provider-native APIs where required.

## Heartbeat and progress

Control-plane leases already exist.

The managed host direction adds worker-host progress so liveness is not inferred only from a long synchronous HTTP request.

Potential progress payload:

~~~text
execution_id
attempt
phase
heartbeat timestamp
resource summary
optional progress message
~~~

The exact protocol is future work.

The host heartbeat must preserve exact-attempt fencing from docs/execution-leases.md.

## Security boundary

The managed executor must not receive:

- GitHub App private key;
- GitHub webhook secret;
- broad organization credentials.

Private repository access remains a separate short-lived repository-scoped read capability.

Repository credentials must not be written to the Resource Journal or portable Result.

Customer source lives only in the disposable execution workspace unless customer policy explicitly requests artifact retention.

See RFC 0007 for the broader source-code boundary.

## Implementation sequence

### Phase 1

- standalone Go executor skeleton;
- Execution Plan input;
- lifecycle phases;
- process supervision;
- cancellation;
- resource journal;
- cleanup/sweeper proof;
- process/cgroup metrics.

### Phase 2

- cgroup v2 controlled-host backend;
- namespace isolation;
- controlled networking;
- OTLP/Collector integration;
- local evidence bus;
- provider adapter integration.

### Phase 3

- Performance calibration and same-lease pairing;
- stronger disk/network accounting;
- snapshot/cache primitives where safe.

### Phase 4

- Firecracker runtime backend;
- Deep sensors/eBPF;
- reference execution fleet;
- stronger isolation policies.

## Consequences

### Positive

- executor operational behavior is explicit;
- process cleanup becomes deterministic;
- host-level Performance/Deep evidence becomes possible;
- cgo/native dependency risk stays out of the supervisor;
- sensors can evolve independently;
- cancellation can stop compute promptly;
- leaked resources are recoverable after executor crashes;
- Firecracker remains optional and composable.

### Costs

- host agent and sweeper increase operational complexity;
- namespace/network isolation is platform-specific;
- Firecracker requires KVM-capable controlled infrastructure;
- evidence IPC and sensor lifecycle need versioned contracts;
- external providers cannot expose every host capability.

## Non-goals

This RFC does not:

- claim these controls are all implemented today;
- replace the current proven Rails executor-service boundary immediately;
- require Firecracker for all executions;
- require eBPF for Standard evidence;
- define provider placement policy;
- define Behavioral Diff;
- define public customer configuration syntax;
- make Go part of the portable Result contract.

## Related work

- ADR 0007: Automatic placement and paired performance execution
- ADR 0013: Managed executor is Go; sensors stay out of process
- RFC 0004: Execution planning, compute, placement, and evidence strategy
- RFC 0006: Portable execution and multi-source evidence
- RFC 0007: Repository configuration, review workload, and source-code boundary
- docs/executor.md
- docs/execution-leases.md
- docs/customer-code-execution-boundary.md
- docs/production-runtime.md
