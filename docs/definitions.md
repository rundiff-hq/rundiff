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
