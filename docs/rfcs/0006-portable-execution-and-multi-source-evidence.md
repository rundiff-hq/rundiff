# RFC 0006: Portable execution and multi-source evidence

## Status

Draft.

## Context

RunDiff's current customer execution path is intentionally narrow:

```text
Rails
  + PostgreSQL or SQLite
  + rundiff.yml
```

The Behavioral Diff core is already more portable than the current subject runtime. The current limitation is evidence capture and subject bootstrapping, not the comparison model itself.

RunDiff should evolve without turning Rails, OpenTelemetry, Docker, eBPF, or any single runtime into the permanent product boundary.

The product question remains:

> What did this software change actually change?

## Product position

Traditional observability primarily explains systems that are already running. RunDiff moves behavioral comparison earlier in the lifecycle.

A concise positioning statement is:

> Observability tells you what broke after deploy. RunDiff tells you before.

This is a lifecycle distinction, not a claim that observability products only work in production. Existing observability systems can be used in staging or pre-production too. RunDiff's specific job is deterministic A/B comparison of a software change before it is accepted.

```text
change
  -> pull request
  -> RunDiff A/B execution
  -> behavioral decision
  -> merge/deploy
  -> production observability
```

RunDiff should complement systems such as Datadog, Honeycomb, Grafana, and other observability platforms rather than trying to become a generic production monitoring backend.

## Core decision

Treat evidence collection as a set of independent providers feeding a normalized RunDiff evidence model.

```text
framework-native instrumentation --+
OpenTelemetry ----------------------+
eBPF -------------------------------+--> normalizer --> RunDiff Evidence --> Behavioral Diff
cgroups/process metrics ------------+
HTTP/network probes ----------------+
driver-native artifacts ------------+
```

No provider owns the RunDiff domain model.

In particular:

- RunDiff Evidence must not become an OpenTelemetry schema.
- Rails ActiveSupport::Notifications must not become the universal instrumentation contract.
- eBPF must not become mandatory for correctness.
- Docker must not become the only subject runtime.
- language-specific implementation details must stay behind portable execution and evidence contracts.

## Evidence layers

### Layer 1: framework-native evidence

Framework-native hooks provide the highest semantic fidelity when available.

For Rails, the current path uses ActiveSupport::Notifications and related Rails instrumentation to capture signals such as:

- SQL queries;
- Active Job activity;
- mail delivery;
- outbound HTTP activity;
- runtime errors;
- request timing.

This remains the preferred high-fidelity Rails provider.

Framework-native evidence can later include equivalents for Django, Node frameworks, JVM frameworks, .NET, or other ecosystems.

The framework provider is an optimization for semantic depth, not a requirement for RunDiff adoption.

### Layer 2: OpenTelemetry

OpenTelemetry should be a first-class portable evidence provider.

An application that already emits traces through OTLP can provide useful cross-language evidence without requiring RunDiff to understand its framework in detail.

Potential evidence includes:

- request/server spans;
- database spans;
- outbound HTTP/client spans;
- queue and messaging spans;
- errors;
- distributed causality;
- operation latency.

Conceptually:

```text
Rails / Node / Java / Go / Python / .NET
                  |
                 OTLP
                  |
          RunDiff OTel provider
                  |
          normalized evidence
```

RunDiff should prefer OpenTelemetry and W3C Trace Context for distributed causality, consistent with ADR 0004.

OpenTelemetry is a provider and correlation standard, not the RunDiff storage or comparison model.

### Layer 3: host and process evidence

Before deep eBPF support, ordinary Linux process and cgroup evidence can provide a useful zero-code baseline.

Potential signals include:

- wall time;
- CPU time;
- peak RSS / memory;
- OOM events;
- disk I/O;
- process count;
- thread count;
- network bytes;
- exit status.

This layer is framework-independent and is particularly valuable for containerized or process-isolated A/B execution.

### Layer 4: eBPF and kernel evidence

eBPF is a strategic zero-code evidence provider for RunDiff-managed Linux executors.

Potential signals include:

- socket activity;
- network flows;
- TCP latency and retransmits;
- syscalls;
- file-system activity;
- scheduler/kernel latency;
- process relationships;
- low-level CPU and runtime behavior.

eBPF can make RunDiff useful for arbitrary applications without modifying application code, but it does not replace framework-native or OpenTelemetry instrumentation when semantic application evidence is required.

Examples:

```text
eBPF can observe:
  outbound connections 3 -> 17
  TCP retransmits      0 -> 14
  network bytes        2 MB -> 9 MB

Rails-native evidence can explain:
  User Load queries    1 -> 17
  SendInvoiceJob       1 -> 4
  delivered email      1 -> 2
```

The strongest review may combine independent evidence sources.

```text
DATABASE_QUERY_REGRESSION

Rails-native SQL count    +82%
OTel database spans       +81%
host/network evidence     +77%
CPU time                  +31%
```

Evidence provenance must always be preserved. RunDiff must not invent equivalence between signals from different providers.

## Generic black-box subject

The long-term generic execution boundary should support a subject that RunDiff can build/start/observe without understanding its application framework.

Conceptually:

```text
prepare
  -> build
  -> start
  -> healthcheck
  -> execute scenario
  -> collect evidence
  -> stop
  -> cleanup
```

A future Docker/process subject may be able to execute:

```text
Ruby
Go
Node
Python
Java
Rust
or another runtime
```

with a minimal black-box evidence profile such as HTTP result, latency, CPU, memory, network and process behavior.

Framework adapters can then enrich the same execution with deeper evidence.

```text
Generic subject
   |
   +-- Rails provider
   +-- OpenTelemetry provider
   +-- eBPF provider
   +-- cgroup/process provider
```

The current Rails + PostgreSQL/SQLite path remains the first supported vertical slice. Non-Rails support is future work and must not be claimed as current product capability.

## Executor language independence

The RunDiff Executor is a protocol/runtime role, not a language choice.

It may be implemented in Ruby, Go, Rust, Node, Zig, C/C++, or another suitable language as long as it preserves the execution contracts.

The executor may need to:

- clone exact revisions;
- manage worktrees;
- spawn processes;
- build/start containers;
- manage filesystems;
- manage network/process isolation;
- collect cgroup/process evidence;
- access host capabilities such as eBPF;
- enforce cancellation, timeouts and cleanup;
- return portable Result contracts.

Go is a plausible implementation choice for orchestration because of deployment simplicity, concurrency and systems tooling. Rust is a plausible choice for low-level sensors and eBPF work. Neither language is part of the product contract.

Do not name architectural components by their implementation language.

Use:

```text
RunDiff Executor
RunDiff Sensor
RunDiff Evidence Provider
```

not:

```text
Go Executor
Rust Sensor
```

unless describing a concrete implementation.

## Rails runner is not the RunDiff runner

`bin/rails runner` is one mechanism for executing Ruby code inside a booted Rails environment. It is not the RunDiff orchestration boundary.

A future executor can be implemented in another language and still run a Rails subject:

```text
RunDiff Executor
      |
      -> boot Rails application
      -> execute HTTP scenario
      -> collect evidence
      -> stop Rails application
```

For request-level black-box scenarios, RunDiff may prefer starting the Rails server and driving it externally rather than using `rails runner`.

Rails is required to boot a Rails application. Rails is not required to implement RunDiff orchestration.

## Portable diff core

Portable means independent of the subject framework and executor implementation, not a specific programming language.

The desired boundary is:

```text
baseline evidence
candidate evidence
       |
       v
Behavioral Diff
       |
       v
ALLOW / BLOCK / MANUAL_REVIEW_REQUIRED / INFRA_FAILURE
```

The current implementation can remain Ruby while the contracts stay portable.

A future implementation could be extracted into another runtime, including a Rust library or WebAssembly module, if an independent consumer or runtime justifies the extraction.

WebAssembly is more suitable for deterministic comparison/rules than for host orchestration such as Docker, cgroups, eBPF, filesystem management or process supervision.

Do not rewrite the existing Ruby diff engine merely to achieve implementation-language novelty. Extract only when there is a concrete runtime, performance, distribution or reuse requirement.

## Suggested evolution

The preferred incremental order is:

```text
current
  Rails native evidence
      |
next
  + cgroup/process metrics
      |
then
  + OTLP/OpenTelemetry ingestion
      |
then
  + generic Docker/process subject
      |
then
  + eBPF/host evidence on managed executors
```

This order preserves the proven Rails vertical slice while progressively removing framework dependence.

## Consequences

### Positive

- RunDiff can grow beyond Rails without redesigning Behavioral Diff.
- Existing OTel users gain a low-friction integration path.
- Managed executors can provide zero-code evidence through process metrics and eBPF.
- Rich framework evidence and generic black-box evidence can coexist.
- Executor implementation language can change without changing customer contracts.
- RunDiff stays complementary to production observability instead of becoming another monitoring backend.

### Costs

- evidence normalization and provenance become first-class concerns;
- different providers expose different fidelity and capabilities;
- eBPF requires controlled Linux host capabilities and stronger security boundaries;
- cross-provider evidence correlation needs explicit identity rules;
- generic black-box execution needs a safe setup/build/start/healthcheck contract.

## Non-goals

This RFC does not:

- claim current non-Rails customer support;
- require rewriting the current Rails implementation;
- select Go or Rust as a mandatory implementation language;
- require eBPF for the first production proof;
- replace deterministic RunDiff evidence with an LLM;
- define a universal customer shell-command configuration language;
- turn RunDiff into a production observability backend.

## Related work

- ADR 0001: Rails monolith first
- ADR 0002: Execution is the core abstraction
- ADR 0004: OpenTelemetry and W3C context
- RFC 0002: Runner adapter contract
- RFC 0004: Compute and executor strategy
- `docs/subject-environments.md`
- `docs/arbitrary-rails-bootstrap.md`
- `docs/current-state.md`
