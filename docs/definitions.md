# RunDiff definitions

This document is the canonical short glossary for current product and architecture terminology.

When older RFCs or issues use broader historical terms, prefer the definitions here and the accepted ADRs.

## Behavioral Review

The customer-facing product concept for evaluating one software change or candidate against an appropriate baseline using selected execution evidence.

A Behavioral Review may originate from:

- a pull request;
- an AI-generated patch;
- a candidate branch;
- a merge-queue candidate;
- one of several generated solutions;
- a local or agent evaluation flow.

Behavioral Review is intentionally broader than Pull Request.

## Run

A durable comparison request for one scenario/change relationship.

A Behavioral Review may contain one or more Runs.

## Execution

One scenario/workload execution against one exact subject revision/environment.

Typical comparison:

~~~text
Run
├── baseline Execution
└── candidate Execution
~~~

## Review Workload

The selected set of tests, scenarios, commands, flows, or benchmarks that RunDiff should execute for a Behavioral Review.

It is not synonymous with the repository's entire CI suite.

Selection may be explicit, dynamic, or full.

## Workload Catalog

Derived metadata describing discoverable workload items such as tests/scenarios, paths, names, tags, and estimated duration.

The catalog is customer data even when it does not contain full source code.

## Workload Profile

Infrastructure-facing description of what an execution requires.

It may include:

- runtime/framework;
- services;
- CPU/RAM/disk;
- architecture;
- Docker/Compose requirements;
- network/privilege requirements;
- expected duration;
- requested Evidence Depth;
- parallelism;
- repository-specific historical resource envelope.

## Execution Plan

The control-plane composition describing how one execution will run.

It may include:

- Execution Orchestrator;
- Compute Provider;
- Runner Backend;
- Runtime/Isolation;
- resources/region;
- parallelism;
- Evidence Depth;
- comparison strategy;
- placement/fallback policy.

Execution Plan supersedes the earlier idea of one flat Execution Provider string.

## Execution Orchestrator

The scheduler/control system that owns the job graph or external CI lifecycle.

Examples:

- RunDiff native scheduler;
- GitHub Actions;
- Buildkite;
- GitLab CI;
- CircleCI.

## Compute Provider

The infrastructure that supplies machine/sandbox/worker capacity.

Examples include RunDiff Fleet and external programmable compute platforms.

A vendor name alone does not determine Evidence Depth.

## Runner Backend

Optional infrastructure below an external orchestrator.

For GitHub Actions, examples may include GitHub-hosted runners, Blacksmith, Depot, WarpBuild, RunsOn, or customer self-hosted fleets.

## Runtime / Isolation

How customer code is isolated and executed after compute is acquired.

Examples:

- process;
- Docker/OCI;
- Kubernetes;
- VM;
- Firecracker microVM.

Firecracker is a runtime/isolation primitive, not an Execution Provider.

## Subject Environment

Application-facing lifecycle boundary that prepares the customer software and dependencies for execution.

It owns framework/database/service setup, not infrastructure placement.

## Evidence Provider

A source of observations.

Examples:

- framework-native instrumentation;
- OpenTelemetry;
- process/cgroup metrics;
- eBPF;
- network probes;
- browser/native test artifacts.

## Evidence Depth

The requested product-level depth of evidence.

### Standard

Behavioral evidence with broad portability.

### Performance

Standard plus controlled resource comparison, calibration/noise awareness, and paired baseline/candidate execution.

### Deep

Performance plus explicitly supported host/kernel/system evidence such as eBPF, syscalls, scheduler, network, or block-I/O signals.

Deep is a capability of the complete Execution Plan, not a permanent property of a vendor.

## Placement Engine

Control-plane component that chooses an Execution Plan.

Initial implementation is deterministic, rule-based, capability-driven, and explainable.

## Execution Stability Profile

Measured noise/stability dimensions for an execution environment, for example CPU, memory, disk, network, or startup.

It is not one permanent provider determinism score.

## Review Credits

Working normalized accounting abstraction for RunDiff-managed compute.

Review Credits may incorporate resource shape, duration, parallelism, and provider economics.

The exact public conversion is not yet a contract.

## Ownership Resolver

Component that maps findings/affected behavior to owners.

Initial source: CODEOWNERS.

Future sources may include scenario ownership or service catalogs.

Ownership does not imply causality.

## Routing Engine

Component that converts findings plus ownership/policy/confidence into delivery actions.

It does not change Behavioral Diff.

## Notification / Action Adapter

Destination integration used by the Routing Engine.

Examples:

- GitHub;
- Slack;
- Microsoft Teams;
- Discord;
- Telegram;
- email;
- generic webhook;
- issue/incident systems;
- future AI agents.

## Repository Configuration

The canonical repository-owned configuration file:

~~~text
/rundiff.yml
~~~

It is framework-neutral and source-control-neutral.

Git is the source of truth for execution intent.

## Source-Code Boundary

Preferred hosted trust boundary:

- source code is cloned into a disposable execution environment;
- the Rails control plane does not need to persist the repository checkout;
- the control plane receives only required derived metadata/evidence/artifacts;
- repository clone capability is short-lived and repository-scoped.

Derived metadata can still be sensitive and must be treated as customer data.

## GitHub Configuration Handoff

The standard hosted setup/update flow where RunDiff generates rundiff.yml and opens GitHub's browser UI so the authenticated user reviews and commits the change through Git.

Normal configuration onboarding should not require permanent repository Contents: write permission for the RunDiff App.


## RunDiff Sensor

Out-of-process or separately deployed evidence collector used by the managed Executor.

Examples may include eBPF, process, network, or runtime-specific sensors.

Sensors communicate through explicit language-neutral evidence/IPC contracts and must not require cgo inside the Go supervisor.

## Resource Journal

Executor-local append-only record of resources created for an execution so teardown can be retried after crashes.

Typical resource classes include workspaces, cgroups, namespaces, processes, containers, microVMs, and temporary artifacts.

The Resource Journal is operational recovery state, not Behavioral Review evidence.

## Sweeper

Independent cleanup/reconciliation mechanism that removes leaked executor resources after a lease is terminal/expired or an executor process disappears.

The sweeper must preserve exact execution/lease fencing and must never reap resources belonging to a live execution.

## External Orchestrator Bridge

Execution path in which RunDiff delegates job execution to an existing customer orchestration system such as GitHub Actions, Buildkite, GitLab CI, or CircleCI while retaining RunDiff control-plane authority for the Behavioral Review.

This is distinct from a direct Compute Provider integration.


## Evidence

A recorded observation or measurement produced by an execution/evidence provider.

Examples include SQL counts, latency, CPU time, memory, network activity, errors, traces, or artifacts.

Evidence answers:

> What did RunDiff actually observe?

Evidence preserves provenance and is distinct from interpretation.

## Rule

A stable reusable analysis definition.

Example:

~~~text
database.query.count.regression
~~~

A Rule defines semantics such as signal, comparison direction, default severity, evidence requirements, and classification facets.

Rule IDs are durable machine contracts; human titles/messages may evolve.

## Finding

One concrete application of a Rule to one Behavioral Review.

Example:

~~~text
database.query.count.regression
17 -> 31 SQL queries
+82.4%
~~~

A Finding is evidence-backed and may influence policy, but it is not automatically a root cause.

## Diagnosis

An interpretation of one or more Findings/Evidence items.

Examples include CPU-bound request, queue-dominated latency, probable N+1, or downstream dependency slowdown.

Diagnosis carries explicit confidence/basis and may be deterministic, inferred, hypothetical, or confirmed.

## Relation

A typed edge connecting findings, diagnoses, dependencies, or evidence-derived entities.

Examples:

~~~text
depends_on
contributes_to
causes
correlates_with
upstream_of
downstream_of
same_cause_as
~~~

Relations carry epistemic status such as observed, inferred, hypothesis, or confirmed.

Correlation must not be promoted to causation without sufficient evidence.

## Decision

The policy outcome of a Behavioral Review.

Examples:

~~~text
ALLOW
REVIEW
BLOCK
INFRA_FAILURE
~~~

Decision is distinct from Finding and Diagnosis.

## Execution Failure

A failure of execution infrastructure/workload setup to produce the intended evidence contract.

Examples include provider failure, capability mismatch, bootstrap/build failure, timeout, OOM, cancellation, sensor failure, or cleanup failure.

Execution Failure is not a behavioral Finding about the candidate unless that failure is itself the behavior under comparison.

## Rule Registry

The versioned collection of stable RunDiff Rules.

Current runtime policy still lives in `RunDiff::BehavioralDiff::SIGNALS`; RFC 0010 defines the migration toward a Rule Registry with stable dotted `rule_id` values and faceted classification.


## Control Plane

The implementation-independent RunDiff authority for durable product state and policy.

It owns concepts such as Behavioral Review identity, execution/current-attempt authority, stale/supersede/finalization semantics, publication state, project/install metadata, and execution planning.

A Control Plane implementation may use Rails/PostgreSQL, Cloudflare Workers/D1/Workflows, or another runtime.

Infrastructure primitives are adapters and must not redefine the RunDiff domain model.

The selected hosted production-v1 implementation is Cloudflare-native; the existing Rails application remains a proven reference/fallback implementation.

See ADR 0016 and RFC 0011.
