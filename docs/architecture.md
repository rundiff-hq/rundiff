# Architecture

## Core model

A Behavioral Review is the customer-facing evaluation of one software change or candidate.

A Behavioral Review may contain one or more Runs.

A Run is one comparison request for one scenario/change relationship.

~~~text
Behavioral Review: PR #42

Run: signup-create-project
├── baseline Execution: main@abc123
└── candidate Execution: pr-42@def456
~~~

An Execution is one scenario/workload run against one exact subject revision/environment. It may produce functional results, driver events, traces, logs, measurements, process samples, screenshots/video, native test artifacts, profiles, and side-effect records.

A scenario is durable product intent, not a framework-specific test file.

~~~text
scenario: user.signup.create-project
web implementation: Playwright
mobile implementation: Maestro
api implementation: HTTP/gRPC
~~~

## High-level architecture

~~~text
Git provider / customer change
        |
        v
RunDiff Control Plane
        |
        +--> repository config (/rundiff.yml)
        |
        +--> Workload Discovery / Catalog
        |
        +--> Workload Profiler
        |
        +--> Placement Engine
        |       |
        |       v
        |   Execution Plan
        |
        +--> Execution Orchestrator / Compute
                |
                v
          RunDiff Executor
                |
                +--> Subject Environment
                |
                +--> Evidence Providers
                |
                v
          portable Executor::Result
                |
                v
             Evidence
                |
                v
          Rule / Behavioral Diff
                |
                +--> Findings
                +--> Diagnoses
                +--> Relations / causal graph
                |
                v
             Decision
                |
                +--> Ownership Resolver
                |
                +--> Routing Engine
                |
                v
       GitHub / UI / API / agents / channels
~~~

The control plane remains authoritative for durable product state, policy, leases, stale checks, cancellation, placement, billing/metering, and publication.

The executor owns reliable customer-code execution and evidence production for an assigned Execution Plan.

## Repository configuration

Canonical repository configuration is:

~~~text
/rundiff.yml
~~~

The file is framework-neutral.

Git is the source of truth for Review Workload and repository-owned execution intent.

The control panel may generate and visually edit configuration, but committed Git configuration is authoritative for a reviewed revision.

See RFC 0007.

## Review Workload

Review Workload is the selected set of tests, scenarios, commands, flows, or benchmarks that participate in a Behavioral Review.

It is independent from the repository's entire CI suite.

Selection can be explicit, dynamic such as changed/related, or full.

Workload Discovery happens inside an execution environment or customer CI boundary and can publish a derived catalog to the control plane.

## Execution planning

The infrastructure composition boundary is Execution Plan.

An Execution Plan may independently describe orchestrator, compute provider, runner backend/provenance, runtime/isolation, resources/region, parallelism, Evidence Depth, comparison strategy, and placement/fallback policy.

Vendor identity is not an architectural role.

See RFC 0004 and docs/definitions.md.

## Subject environment

Subject Environment prepares the application being measured.

It owns framework/database/service lifecycle rather than infrastructure placement.

Examples include Rails + PostgreSQL, Rails + SQLite, and future generic Docker/process subjects.

See docs/subject-environments.md.

## Evidence providers

Evidence can come from several independent layers:

~~~text
framework-native --------+
OpenTelemetry -----------+
process / cgroup --------+--> normalized evidence
eBPF --------------------+
network probes ----------+
driver artifacts --------+
~~~

No evidence provider owns the RunDiff domain model.

See RFC 0006.

## Behavioral analysis model

RunDiff separates transport, evidence, analysis, diagnosis, and policy.

~~~text
Executor::Request
      |
      v
Execution
      |
      v
Executor::Result
      |
      v
Evidence
      |
      v
Rule
      |
      v
Finding
      |
      +--> Diagnosis
      +--> Relations / causal graph
      |
      v
Decision
~~~

Execution Failure is separate from Finding.

Examples:

~~~text
Execution Failure
  provider timeout
  OOM
  clone failure

Finding
  database.query.count.regression
  17 -> 31 queries

Diagnosis
  probable N+1

Decision
  BLOCK
~~~

Findings use orthogonal facets rather than one category tree. Useful facets include domain, quality dimension, resource, scope, change kind, and causal role.

OpenTelemetry Semantic Conventions inform normalized evidence vocabulary where appropriate. SARIF informs Rule/Finding/export design. ISO/IEC 25010:2023 informs high-level quality dimensions. IEC 62740 informs future investigation/root-cause semantics. RunDiff retains its own internal domain model.

Current schema v1 reason codes remain compatible while stable dotted Rule IDs are introduced incrementally.

See RFC 0010 and docs/rules/README.md.

## Correlation

Use separate IDs:

- review identity - product-level Behavioral Review;
- run_id - one comparison;
- execution_id - one subject execution;
- trace_id - one distributed causal trace;
- span_id - one operation.

One execution can contain many traces.

Preferred propagation is W3C traceparent plus baggage such as rundiff.execution.id. In controlled test environments, X-RunDiff-Execution-Id is also acceptable.

Propagate through HTTP/gRPC, jobs, Temporal, internal services, logs/spans, and controlled emulators. Do not blindly leak internal baggage to untrusted providers.

Do not put execution_id on metric labels. It is high cardinality; use exemplars or execution-level aggregation.

## Source-code boundary

The Control Plane should not persist a customer repository checkout.

Preferred managed path:

~~~text
short-lived read capability
  -> disposable execution environment
       -> clone
       -> discover
       -> execute
       -> collect evidence
       -> cleanup
~~~

The control plane receives derived metadata/evidence according to policy.

Derived metadata is still customer data.

Customer Hosted and external CI can keep source entirely inside customer infrastructure.

See RFC 0007 and docs/executor.md.

## Performance architecture

Performance evidence is not an absolute cloud benchmark claim.

Preferred model:

~~~text
same lease / comparable environment
  -> calibrate
  -> BASE
  -> PR
  -> optional interleaving/repetition
  -> compare against measured noise
~~~

Parallelism is explicit in Execution Plan and must be comparable for Performance.

See RFC 0004.

## Ownership and routing

After Behavioral Diff, RunDiff can resolve who owns affected behavior and route the finding.

~~~text
Finding
  -> Ownership Resolver
  -> Routing Policy
  -> GitHub / channel / webhook / agent
~~~

CODEOWNERS is the preferred first ownership source.

Ownership is not causality.

See RFC 0008.

## Control Plane implementation boundary

RunDiff Control Plane is an implementation-independent product/domain authority.

The first hosted production implementation is Cloudflare-native:

~~~text
React SPA
  -> Hono Worker API
      +-> D1
      +-> Cloudflare Workflows
      +-> R2
      +-> GitHub API/App
      +-> Execution Dispatcher
~~~

Rails remains a proven reference/fallback implementation. Cloudflare bindings must stay behind adapters so a future Rails/PostgreSQL/Temporal or other implementation can preserve the same domain contracts.

See ADR 0016 and RFC 0011.

## Storage

Durable product metadata is stored through a persistence adapter.

Production v1 uses D1. A future implementation may use PostgreSQL or another transactional store without redefining the RunDiff domain model.

Large immutable evidence belongs in an artifact store such as R2/S3, including Playwright traces, screenshots/video, rrweb recordings, HAR, profiles, compressed logs, mobile recordings, and other retained artifacts.

Repository source code should not be treated as a durable control-plane storage object by default.

## Extraction seams

Potential future packages:

- rundiff-protocol;
- rundiff-cli;
- rundiff-playwright;
- rundiff-recorder;
- rundiff-otel;
- rundiff-mobile;
- rundiff-github;
- executor/discovery packages by runtime where justified.

Extract only when a component gains an independent runtime, language, release cadence, or external consumer.
