# RFC 0004: Execution planning, compute, placement, and evidence strategy

## Status

Accepted direction. Implementation is incremental.

Last major model revision: 2026-09-20.

## Context

RunDiff compares software behavior between a baseline and one or more candidates. It therefore needs real execution compute, not only static repository analysis.

The original version of this RFC used a flat Execution Provider abstraction. That was useful for the first design pass, but it is too small for the real market and for RunDiff's likely architecture.

A single vendor can provide more than one role:

- Buildkite can be a CI orchestrator and can also provide hosted agents.
- GitHub Actions is an orchestrator and also has hosted runners.
- Namespace can participate as GitHub Actions runner infrastructure and as general compute for development workloads.
- E2B, Vercel Sandbox, Cloudflare Sandbox, Daytona, Fly Machines, and similar systems expose direct programmable compute or sandbox primitives.
- Blacksmith, Depot, WarpBuild, and RunsOn primarily sit below GitHub Actions as runner backends.
- Firecracker is not a provider at all. It is an isolation primitive.
- OpenTelemetry and eBPF are evidence sources, not compute providers.

RunDiff therefore needs a compositional execution model.

The durable question is not:

> Which provider do we use?

It is:

> What exact execution plan satisfies this workload, evidence, policy, stability, and cost requirement?

The core product question remains:

> What did this software change actually change?

## Decision summary

1. The Rails control plane owns durable product state, policy, GitHub integration, leases, stale guards, cancellation authority, placement, publication, and commercial metering.
2. The managed RunDiff Executor is implemented in Go. It is an execution supervisor, not a Docker container as a product boundary.
3. Execution Plan is the top-level placement and launch abstraction.
4. An Execution Plan composes multiple independent roles: orchestrator, compute, optional runner backend, runtime/isolation, resources, parallelism, evidence profile, and placement policy.
5. Vendor identity is not an architectural role. One vendor may fill multiple roles.
6. Workload Profiler derives requirements. Placement Engine produces an Execution Plan.
7. The first Placement Engine is deterministic, rule-based, explainable, and capability-driven.
8. RunDiff collects empirical placement evidence and repository-specific history before introducing predictive scheduling.
9. Preview should use customer-funded execution through GitHub Actions or another supported customer orchestrator where practical.
10. Paid hosted plans use RunDiff-managed placement and compute by default.
11. Review volume and Evidence Depth are independent product dimensions.
12. Evidence Depth has three working levels: Standard, Performance, and Deep.
13. Performance claims are confidence-gated by measured execution noise.
14. Paired baseline/candidate execution on the same lease is preferred over absolute cross-machine benchmarking.
15. Parallelism is part of the Execution Plan and must be held comparable for Performance evidence.
16. Aggregate compute usage must account for parallel workers. Wall-clock duration alone is not a valid billing unit.
17. Review Credits are the preferred working abstraction for normalized managed compute, but the exact public normalization is not yet a contract.
18. Behavioral Review is the preferred customer-facing usage concept. PR count is not a durable product unit.
19. Firecracker is a controlled-fleet isolation option, not a determinism guarantee.
20. RunDiff must not implement naive CI x 2 or CI x 3. Candidate evidence reuse, baseline reuse, snapshots, and selective scenarios remain strategic.
21. Deep evidence requires explicit host/runtime capabilities and must never silently degrade while retaining the Deep label.
22. Deterministic evidence and behavioral diff remain the correctness path. LLM explanation stays downstream and optional.

## Core architecture

~~~text
Git provider / webhook
        |
        v
RunDiff Rails Control Plane
        |
        +--> Workload Profiler
        |       |
        |       v
        |   Workload Profile
        |
        +--> Placement Engine
                |
                v
          Execution Plan
                |
      +---------+----------+
      |                    |
      v                    v
RunDiff-native path   External orchestrator bridge
      |                    |
      v                    v
managed compute       GitHub Actions / Buildkite /
or BYOC compute       GitLab CI / CircleCI / other
      |                    |
      +---------+----------+
                |
                v
          RunDiff Executor
                |
                v
      Subject + Evidence Providers
                |
                v
          Portable Result
                |
                v
     Behavioral Diff + Policy
                |
                v
     GitHub / API / agent surfaces
~~~

The RunDiff control plane remains authoritative even when an external CI system performs execution.

## Terminology

### Workload Profile

A Workload Profile describes what an execution needs before placement.

It can contain:

- language and framework;
- service topology;
- Docker / Compose requirements;
- CPU, memory, disk, and architecture estimates;
- privileged requirements;
- custom networking;
- nested container or VM requirements;
- expected duration;
- requested Evidence Depth;
- required evidence capabilities;
- data residency and network requirements;
- expected parallelism;
- historical repository resource envelope;
- cache and snapshot opportunities.

Illustrative profile:

~~~text
subject:
  runtime: ruby
  framework: rails

services:
  - app
  - postgres
  - redis
  - sidekiq

requirements:
  docker_compose: true
  privileged: false
  custom_networking: false
  nested_virtualization: false
  architecture: amd64

estimated:
  cpu: 2
  memory_gb: 3.2
  duration_seconds: 240

evidence:
  depth: performance
  paired_execution: true
  ebpf: false

parallelism:
  current_test_workers: 4
~~~

### Execution Plan

Execution Plan is the main output of placement.

It describes how one RunDiff execution will actually happen.

Illustrative, non-contractual shape:

~~~yaml
execution_plan:
  orchestrator:
    kind: rundiff

  compute:
    provider: e2b
    region: eu
    shape: standard-4

  runner_backend:
    kind: direct

  runtime:
    isolation: microvm
    workload: oci

  resources:
    cpu: 4
    memory_gb: 8
    architecture: amd64

  parallelism:
    mode: controlled
    shards: 4
    workers_per_shard: 1

  evidence:
    depth: performance

  comparison:
    paired_lease: true
    interleave: true

  policy:
    provider_fallback: allowed
    data_region: eu
~~~

Another valid plan may use customer CI:

~~~yaml
execution_plan:
  orchestrator:
    kind: buildkite

  compute:
    provider: customer_managed

  runner_backend:
    kind: existing_buildkite_queue

  runtime:
    isolation: external

  parallelism:
    mode: preserve_customer

  evidence:
    depth: standard
~~~

The schema above is explanatory. It is not yet a public configuration or wire contract.

### Execution Orchestrator

The orchestrator schedules jobs and owns the job graph or external CI lifecycle.

Possible orchestrators include:

- RunDiff native scheduler;
- GitHub Actions;
- Buildkite;
- GitLab CI;
- CircleCI;
- Harness or another customer CI platform.

RunDiff-native orchestration is preferred when RunDiff owns managed compute because adding a second CI scheduler is unnecessary.

External orchestrators are valuable for Preview, BYOC, existing enterprise CI, private networks, and imported candidate evidence.

### Compute Provider

Compute Provider is the substrate that provides a machine, sandbox, container host, or worker capacity.

Examples and candidates include:

- RunDiff Fleet;
- Cloudflare Sandbox / Containers;
- E2B;
- Vercel Sandbox;
- Fly Machines;
- Namespace;
- Daytona;
- Modal;
- customer AWS/GCP/Azure/on-prem;
- other programmable execution systems.

A compute provider does not automatically imply a specific Evidence Depth.

Capabilities belong to the actual execution plan: provider + runtime + privileges + resource shape + policy.

### Runner Backend

Runner Backend is an optional layer below an external CI orchestrator.

For GitHub Actions this may include:

- GitHub-hosted runners;
- Blacksmith;
- Depot;
- WarpBuild;
- RunsOn;
- customer self-hosted runners;
- Actions Runner Controller or another customer fleet.

The key point is that RunDiff may integrate with GitHub Actions once and discover runner provenance without needing a first-party adapter for every GitHub runner vendor.

Similar concepts exist for Buildkite agent queues, GitLab runners, and CircleCI runners.

Runner Backend is therefore optional in an Execution Plan and may be opaque to RunDiff.

### Runtime / isolation backend

Runtime describes how customer code is isolated after compute has been acquired.

Examples:

- local process;
- OCI / Docker container;
- containerd workload;
- Kubernetes pod;
- full VM;
- Firecracker microVM;
- another microVM or hypervisor boundary.

Runtime and Compute Provider are separate.

### Evidence Provider

Evidence Provider produces observations.

Examples:

- Rails or framework-native instrumentation;
- OpenTelemetry;
- process and cgroup metrics;
- eBPF;
- network probes;
- driver-native artifacts;
- browser traces;
- native test framework artifacts.

Evidence Provider is defined further in RFC 0006.

### Subject Environment

Subject Environment prepares the customer's application and its dependencies.

This remains the boundary defined in docs/subject-environments.md and is separate from infrastructure placement.

### Placement Engine

Placement Engine transforms a Workload Profile and organization policy into one or more candidate Execution Plans and selects a compatible plan.

### Behavioral Review

Behavioral Review is the customer-facing product unit: one meaningful baseline/candidate review of a change or candidate.

It is intentionally broader than Pull Request.

A Behavioral Review may originate from:

- a human PR;
- an AI-generated patch;
- a candidate branch;
- a merge queue candidate;
- one of several generated solutions;
- a pre-commit or agent evaluation flow.

This keeps the product model useful if AI systems generate far more candidate changes than human teams historically generated PRs.

## Native execution and external orchestration

### RunDiff-native managed execution

Preferred managed path:

~~~text
Rails Control Plane
  -> Workload Profiler
  -> Placement Engine
  -> Execution Plan
  -> direct Compute Adapter
  -> Go Executor
  -> subject runtime
  -> evidence
~~~

This avoids unnecessary scheduler nesting.

### External orchestrator bridge

Customer-controlled path:

~~~text
Rails Control Plane
  -> GitHub Actions / Buildkite / GitLab / CircleCI
  -> customer's existing runner topology
  -> RunDiff execution/instrumentation
  -> evidence export
  -> Rails Control Plane
~~~

This is important where customers already have:

- large test sharding;
- tuned caches;
- private services;
- VPN access;
- custom databases;
- special hardware;
- internal security policy.

RunDiff should not force these customers to reproduce mature CI topology inside a generic managed sandbox just to adopt Behavioral Review.

## Market map and prior art

This section is non-normative. It records architecture references and provider candidates verified around 2026-09-20. Vendor capabilities change and must be re-verified before implementation decisions.

### CI orchestrators

#### Buildkite

Buildkite is strong prior art for separating a SaaS control plane from execution agents. It supports both customer-hosted agents and Buildkite-hosted agents.

RunDiff relevance:

- external orchestrator bridge;
- enterprise existing-CI integration;
- candidate evidence import;
- architecture reference for control-plane / data-plane separation;
- parallel test topology that RunDiff must understand rather than flatten.

#### GitLab Runner autoscaling

GitLab Runner's current autoscaling architecture separates runner management, autoscaling logic, VM abstraction, and cloud provider plugins.

RunDiff relevance:

- strong prior art for provider abstraction;
- reinforces capability-driven provisioning;
- useful reference for fleet lifecycle and cloud plugin boundaries.

#### CircleCI

CircleCI supports self-hosted container and machine runners. Its Machine Runner Orchestrator can scale full VMs through Kubernetes/KubeVirt.

RunDiff relevance:

- external orchestrator bridge;
- prior art for resource classes and ephemeral VM execution;
- reference for separating orchestration from runner provisioning.

#### GitHub Actions

GitHub Actions remains the most important Preview path because customer workflow execution can fund free-tier compute.

It is also an orchestration layer above multiple runner backends.

### GitHub Actions runner backends

Blacksmith, Depot, WarpBuild, RunsOn, and similar systems should usually be modeled as runner backends, not as top-level RunDiff compute abstractions.

Their architectural value is important:

- ephemeral per-job compute;
- alternative hardware and cache strategies;
- BYOC variants;
- clean lifecycle boundaries;
- runner provenance.

RunDiff should capture runner provenance when available, especially for Performance evidence.

A direct adapter for every runner backend is not an initial requirement.

### Direct sandbox / VM candidates

#### Cloudflare Sandbox / Containers

Candidate for managed burst execution and Standard / confidence-gated Performance workloads.

Working role mapping:

~~~text
external orchestration                RunDiff-managed compute

Cloudflare CI                         RunDiff Control Plane
    |                                      |
    v                                      v
RunDiff API / runner bridge          Execution Plan
                                           |
                                           v
                                   Cloudflare compute adapter
                                           |
                                           v
                                   Cloudflare Sandbox
                                           |
                                           v
                                  Cloudflare Containers
~~~

Cloudflare CI and Cloudflare Containers are deliberately not modeled as the same thing.

Cloudflare CI is an external execution orchestrator, peer to GitHub Actions or Buildkite. It may later invoke RunDiff through a bridge, but it is not a required layer inside the managed executor path.

For direct Cloudflare-managed execution, prefer the Sandbox API as the first adapter surface because it exposes execution-oriented primitives over Cloudflare Containers. Containers remain the underlying compute primitive and may be targeted directly later if Sandbox hides capabilities RunDiff needs.

RunDiff keeps ownership of its own lifecycle and comparison semantics. The Cloudflare adapter must not delegate the meaning of Prepare, Clone, Bootstrap, Build, Start, Ready, Scenario, Collect, Teardown, cancellation, evidence collection, or baseline/candidate comparison to Cloudflare CI.

RunDiff must capability-detect restrictions around networking, nested execution, privileges, architecture, host visibility, performance stability, and available evidence depth. Deep evidence is never inferred from provider identity.

This is intentionally an adapter-level assumption rather than a public protocol dependency. Cloudflare SDK/API changes may alter the adapter without changing the portable Request/Result or Behavioral Review contracts.

#### E2B

Important direct-compute candidate because it provides isolated microVM sandboxes, snapshots, lifecycle APIs, metrics, and BYOC options.

Potential roles:

- managed execution;
- interactive reproduction;
- snapshot/fork experiments;
- customer-cloud deployment.

#### Vercel Sandbox

Important direct-compute candidate with isolated sandbox execution, custom images, and snapshot capabilities.

Potential roles:

- Standard execution;
- benchmarked Performance execution if stability is sufficient;
- reproducible sandbox environments.

#### Daytona

Important sandbox candidate because it offers programmable container and VM environments, snapshots, VM forks, pause/resume, and custom compute regions.

Potential roles:

- managed execution;
- reproduction/debug;
- snapshot and fork experiments;
- customer-supplied compute.

#### Fly Machines

Useful lower-level VM substrate with a direct machine lifecycle API.

Potential role:

- raw managed VM target for RunDiff's own Go executor;
- useful when RunDiff wants to own more of the runtime stack rather than consume a higher-level sandbox API.

#### Namespace

Namespace is relevant in more than one role: high-performance GitHub Actions runner infrastructure and general developer/agent compute.

RunDiff should treat the concrete product/API being integrated as the role, not the vendor name alone.

#### Modal

Watchlist compute/sandbox candidate. It is especially strong for elastic compute and now includes sandbox primitives. Any deeper Linux/VM capability must be re-verified before relying on it for Deep evidence.

### Remote execution architecture references

#### BuildBuddy

BuildBuddy is important prior art for remote runners, Firecracker/OCI execution, warm environments, and snapshot reuse.

The relevant RunDiff lesson is not "use BuildBuddy".

It is:

> baseline environment state may be reusable and forkable instead of rebuilt from zero for every candidate.

This matters to one-baseline-many-candidates economics.

#### EngFlow

EngFlow is useful prior art for scheduler/worker separation and capability-based remote execution.

The relevant RunDiff lesson is:

> incoming work should describe resource and platform requirements, and placement should match those requirements to capable workers.

This directly supports Workload Profile -> Placement Engine -> Execution Plan.

### Specialized architecture references

#### Dagger

Dagger is useful prior art for keeping workflow definition portable across local, cloud, container, and remote engines.

RunDiff should preserve the same principle without taking a dependency unless there is a concrete implementation benefit.

#### Testcontainers Cloud

Testcontainers Cloud demonstrates that application execution and service-container compute can live in different places.

RunDiff should not assume forever that every dependency of a subject must be colocated on one machine.

## Product dimensions

RunDiff pricing should not be a single ladder where more volume automatically means deeper evidence.

### Dimension 1: Review Volume

Working plan names:

- Preview;
- Review 250;
- Review 500;
- Review 1000;
- Enterprise.

These names remain working commercial labels and may change before launch.

The earlier model treated 250 / 500 / 1000 as raw managed minutes. That is too literal because:

- a 2-minute review using one worker is not equivalent to a 2-minute review using 16 workers;
- Performance may execute baseline/candidate repeatedly;
- different machine sizes have different cost;
- providers bill CPU, memory, disk, VM time, or proprietary units differently;
- parallelism reduces wall time without reducing aggregate compute.

RunDiff should therefore not make raw wall-clock minutes the permanent public billing contract.

### Review Credits

Preferred working metering abstraction:

> Review Credits represent normalized managed execution consumption.

The exact formula is not yet a public contract.

A future normalization may use a Standard Worker reference and aggregate resource-time, for example:

~~~text
normalized usage =
  resource-weighted execution time
  + provider-specific normalized cost dimensions
~~~

The model must account for concurrency.

Example:

~~~text
4 workers
x 3 minutes each
= approximately 12 worker-minutes before normalization
~~~

It must not be billed as only 3 minutes merely because the wall clock was 3 minutes.

Do not expose raw provider billing primitives such as Cloudflare CPU seconds, provider-specific VM seconds, or vCPU-minute details as the main customer experience.

### Behavioral Review estimate

Credits are useful for accounting but are still abstract.

The primary human explanation should be estimated Behavioral Reviews.

Before repository history exists:

~~~text
Review 500

Includes N Review Credits

Typical usage:
approximately X Behavioral Reviews
for a representative 5-minute workload
~~~

The public estimate must be labeled approximate.

After RunDiff learns the repository:

~~~text
Based on this repository:

median Behavioral Review: 4m 14s
estimated Review 500 capacity: about 118 reviews/month
~~~

The repository-specific estimate is more useful than a generic PR/day claim.

Do not permanently price by PR count. AI agents can generate orders of magnitude more candidate changes than a traditional human PR workflow.

### Preview

Preview should use customer-funded compute through GitHub Actions or another supported external orchestrator where practical.

Conceptually:

~~~text
customer change
  -> customer CI compute
  -> RunDiff Standard evidence
  -> RunDiff review
~~~

Preview has no RunDiff-managed compute allowance by default.

### Dimension 2: Evidence Depth

#### Standard

Behavioral evidence with broad portability.

Typical signals:

- test/scenario outcome;
- exit status;
- application errors;
- HTTP behavior;
- SQL count/fingerprints where available;
- jobs and side effects where instrumented;
- logs;
- OpenTelemetry;
- process RSS / basic CPU samples;
- native artifacts.

Standard can usually preserve the customer's existing CI parallelism if evidence correlation is strong.

#### Performance

Everything in Standard plus controlled resource comparison.

Typical signals and requirements:

- paired baseline/candidate execution;
- stable resource envelope;
- fixed or comparable worker topology;
- wall time;
- CPU time;
- peak memory;
- memory curve;
- disk I/O;
- process/container metrics;
- calibration;
- measured noise;
- confidence gating;
- repeated/interleaved samples where appropriate.

#### Deep

Everything in Performance plus explicitly supported host/kernel evidence.

Potential signals:

- eBPF;
- syscalls;
- socket/network-flow activity;
- TCP behavior;
- context switches;
- page faults;
- block I/O;
- scheduler/kernel latency;
- process trees;
- low-level file activity;
- flamegraphs/profiles where supported.

Deep requires an Execution Plan whose full capability set can prove those signals.

## Parallelism model

Parallelism affects both evidence quality and commercial metering.

It must be explicit in the Execution Plan.

### Standard mode

Default:

> Preserve customer parallelism when correlation and aggregation remain correct.

For example, 20 RSpec shards can contribute to one Behavioral Review if RunDiff can correlate:

- execution ID;
- scenario/test identity;
- shard ID;
- trace ID;
- evidence provenance.

Ordering differences are acceptable when the evidence semantic is aggregate behavior rather than a timing experiment.

### Performance mode

Performance must freeze or explicitly control:

- shard count;
- worker count;
- CPU allocation;
- memory allocation;
- database pool;
- runtime configuration;
- test seed/order where relevant;
- concurrency against the subject.

Bad comparison:

~~~text
BASE: 8 workers
PR: 12 workers
~~~

Better:

~~~text
BASE: 8 workers
PR: 8 workers
same resource envelope
~~~

Where possible, pair by shard:

~~~text
Shard 1: BASE -> PR
Shard 2: BASE -> PR
Shard 3: BASE -> PR
Shard 4: BASE -> PR
~~~

This is preferable to comparing an unrelated baseline fleet with an unrelated candidate fleet.

### Controlled performance experiment

For endpoint latency, allocations, SQL behavior, or similar micro-level claims, RunDiff may intentionally ignore the customer's normal test-suite parallelism.

Example:

~~~text
fixed subject
fixed database
fixed CPU
fixed concurrency

BASE
PR
BASE
PR
~~~

RunDiff should distinguish:

- CI throughput comparison;
- controlled performance experiment.

They answer different questions.

## Execution stability and confidence

### Do not promise provider determinism

Cloud execution is not perfectly deterministic.

Potential noise sources include:

- physical CPU variation;
- noisy neighbors;
- disk contention;
- network;
- placement;
- thermal behavior;
- cache state;
- cold starts.

RunDiff should record an Execution Stability Profile.

Illustrative:

~~~text
CPU       0.991
Memory    0.987
Disk      0.962
Network   0.814
Startup   0.944
~~~

A single aggregate score may exist for scheduling, but user-facing Performance evidence should retain relevant dimensions.

### Calibration

Potential calibration probes:

- integer / hashing CPU workload;
- compression;
- memory bandwidth;
- local sequential disk;
- local random disk;
- process spawn;
- container or VM startup;
- optional network RTT.

Working implementation hypothesis:

~~~text
median = median(samples)

deviation[i] =
  abs(sample[i] - median) / median

noise95 =
  percentile(deviation, 95)

stability95 =
  1 - noise95
~~~

This formula is not yet a public contract.

### Paired execution

The primary technique is:

> Run baseline and candidate under the same execution lease and as close to the same conditions as possible.

Basic:

~~~text
acquire environment
  -> calibrate
  -> BASE
  -> PR
  -> compare
  -> release
~~~

Higher confidence may interleave:

~~~text
BASE
PR
PR
BASE
BASE
PR
~~~

If an external orchestrator cannot guarantee comparable placement, RunDiff must lower confidence, restrict the claim, or rerun a controlled experiment on a better plan.

### Performance result example

Valid:

~~~text
BASE      182 ms
PR        195 ms
delta     +7.1%

environment noise: +/-1.8%
confidence: HIGH
~~~

Inconclusive:

~~~text
observed delta: +3.1%
environment noise: +/-4.8%
performance conclusion: INCONCLUSIVE
~~~

RunDiff must not turn an inconclusive performance observation into a deterministic regression claim.

## Reference execution

RunDiff may maintain a high-control reference tier.

Possible properties:

- dedicated bare metal;
- fixed CPU model;
- fixed RAM;
- local NVMe;
- fixed kernel and OS image;
- no unrelated workload;
- fixed CPU governor;
- CPU pinning;
- NUMA policy;
- explicit SMT/turbo policy;
- fixed container images;
- fixed random seeds;
- fixed database fixtures;
- controlled or disabled external network.

The reference tier still measures its own noise. It is never assigned a hard-coded 1.000 stability score.

Use cases:

- RunDiff calibration;
- release benchmarks;
- regression confirmation;
- high-confidence customer investigations.

## Placement Engine

### Hard constraints first

Placement rejects incompatible plans before optimization.

Hard constraints may include:

- architecture;
- minimum CPU/RAM/disk;
- required region;
- customer network access;
- privileged operations;
- Docker/Compose behavior;
- nested virtualization;
- KVM;
- eBPF;
- persistent/snapshot requirement;
- approved vendor list;
- BYOC-only policy.

### Optimization second

Among compatible plans, choose according to:

- expected cost / Review Credits;
- measured stability;
- startup latency;
- queue latency;
- cache locality;
- snapshot availability;
- historical success;
- repository-specific history;
- evidence fidelity;
- fallback risk;
- current provider capacity.

### Explainability

A placement decision should be inspectable.

Example:

~~~text
Candidate plan A
  orchestrator: rundiff
  compute: cloudflare
  compatible: yes
  evidence: standard/performance
  expected cost: low
  stability: acceptable

Candidate plan B
  orchestrator: rundiff
  compute: e2b
  compatible: yes
  snapshot support: useful
  expected cost: medium

Candidate plan C
  orchestrator: rundiff
  compute: rundiff_fleet
  compatible: yes
  deep evidence: yes
  unnecessary for requested depth

selected: plan A
~~~

### Fallback

Policy-controlled fallback is allowed for infrastructure failures.

Example:

~~~text
plan A
  -> unsupported runtime behavior / OOM / provider failure
  -> plan B
  -> success
  -> record outcome
~~~

Repository history should prevent repeated avoidable placement failures.

Product regressions must never be silently retried on a different provider until they disappear.

## Placement learning

Record operational metadata outside the portable behavioral Result contract.

Useful dimensions:

- orchestrator;
- compute provider;
- runner backend;
- runtime/isolation;
- region;
- machine/shape;
- observable CPU identity where available;
- architecture;
- workload fingerprint;
- repository;
- language/framework;
- service count;
- container count;
- Evidence Depth;
- planned and actual parallelism;
- estimated and actual RAM;
- estimated and actual CPU;
- bootstrap/build time;
- baseline time;
- candidate time;
- total wall time;
- aggregate worker time;
- calibration/stability profile;
- infra failure reason;
- OOM;
- retries/fallback;
- cache hit rate;
- snapshot reuse;
- evidence bytes;
- network bytes when available;
- normalized Review Credits;
- provider-reported or estimated cost.

Learn at two levels:

1. workload class;
2. exact repository.

Repository-specific history should eventually answer:

~~~text
typical peak RAM
typical CPU
bootstrap duration
common services
stable provider/runtime combinations
normal review duration
normal Review Credit consumption
failure-prone placements
~~~

Predictive models may be introduced only after this data exists and only if they materially outperform transparent rules.

## Reuse and snapshots

RunDiff is not CI x 2.

### Candidate evidence reuse

If equivalent candidate work already ran in customer CI, import evidence when identity and provenance are strong enough.

Required identity should include at least:

- exact candidate SHA;
- exact scenario/test identity;
- compatible environment profile;
- compatible instrumentation;
- trustworthy provenance.

A green exit code alone is insufficient.

### Baseline reuse

Baseline evidence may be reusable when all relevant identity dimensions match.

Potential identity:

~~~text
baseline SHA
scenario identity
subject environment
runtime/toolchain
instrumentation profile
fixture/database identity
relevant secrets/emulator profile
execution-plan compatibility
~~~

### Snapshot/fork opportunity

BuildBuddy, E2B, Vercel Sandbox, Daytona, Firecracker-based systems, and similar technologies demonstrate that environment state can sometimes be snapshotted or forked.

Potential future RunDiff model:

~~~text
prepared baseline environment
        |
        +--> baseline execution
        |
        +--> candidate A
        |
        +--> candidate B
        |
        +--> candidate C
~~~

This can materially change one-baseline-many-candidates economics, especially for AI-generated candidate sets.

Snapshot reuse must not contaminate comparison state.

## Executor role

The concrete managed implementation is Go.

Durable role:

~~~text
RunDiff Executor
  -> accept assigned Execution Plan
  -> prepare repository
  -> bootstrap/build
  -> create subject environment
  -> start/readiness
  -> execute scenario
  -> collect evidence
  -> enforce limits/cancellation
  -> teardown
  -> return portable Result
~~~

The executor coordinates foreign processes and Linux/runtime primitives.

It is not itself defined as a Docker container.

Possible deployment forms:

- host binary/systemd service;
- OCI image;
- Kubernetes DaemonSet;
- agent injected into an external CI job;
- another host-agent form.

On a controlled RunDiff Fleet, a small host-level daemon is preferred when access to cgroups, namespaces, KVM, block devices, eBPF, or host metrics is required.

## Docker, VMs, and Firecracker

Docker/OCI remains an important workload runtime.

It is not the top-level architecture.

Generic managed path:

~~~text
Compute Provider
  -> worker / VM / sandbox
       -> RunDiff Executor
            -> Docker / OCI subject
~~~

Controlled high-isolation path:

~~~text
RunDiff Fleet host
  -> Go Executor
       -> Firecracker microVM
            -> Docker / OCI
                 -> app
                 -> postgres
                 -> redis
                 -> tests
~~~

Firecracker is valuable for isolation, lifecycle, and disposable VM boundaries.

It does not make underlying hardware deterministic.

## Deep evidence

Deep is a capability of an Execution Plan, not a vendor marketing label.

A valid Deep plan may require:

- Linux;
- eBPF-capable kernel;
- sufficient privileges;
- controlled cgroup visibility;
- network namespace visibility;
- process lineage access;
- stable host instrumentation;
- security policy allowing those sensors.

RunDiff Fleet is the expected first environment where these capabilities are under RunDiff's control.

Customer Hosted may also be Deep-capable.

External CI and generic sandboxes should not be assumed Deep-capable without explicit proof.

## Commercial UX

Most customers should see:

~~~text
Execution
  Automatic - recommended
~~~

They should primarily choose:

~~~text
Review volume
  Preview | Review 250 | Review 500 | Review 1000 | Enterprise

Evidence depth
  Standard | Performance | Deep
~~~

The UI may later expose advanced policy:

~~~text
Execution policy
  automatic
  RunDiff managed only
  customer CI
  customer hosted
  approved providers only
  EU-only
  stability over cost
~~~

Customers buy RunDiff outcomes, not Cloudflare or E2B product complexity.

## Implementation sequence

### Phase 1 - Make the model explicit

- introduce WorkloadProfile;
- introduce ExecutionPlan;
- represent orchestrator separately from compute;
- represent optional runner backend/provenance;
- add explicit parallelism fields;
- keep GitHub Actions Preview;
- keep existing portable Request / Result contract;
- collect placement and usage telemetry.

### Phase 2 - First managed placement

- implement one direct Compute Adapter;
- add deterministic Placement Engine;
- add capability records;
- add fallback;
- add Review Credit accounting prototype;
- show estimated Behavioral Reviews from repository history.

### Phase 3 - Multi-provider Performance

- benchmark a second managed compute provider;
- add calibration;
- add same-lease pairing;
- add controlled parallelism;
- add Performance confidence gating;
- add repository-specific placement history.

### Phase 4 - External orchestrator bridges

Priority based on customer demand:

- GitHub Actions first;
- Buildkite as a strong enterprise candidate;
- GitLab CI / CircleCI next where justified;
- import existing candidate evidence;
- preserve customer sharding where safe.

### Phase 5 - Controlled fleet and Deep

- RunDiff Fleet;
- host-level Go executor;
- stronger cgroup/process evidence;
- Firecracker or another microVM runtime where justified;
- eBPF sensors;
- reference execution tier.

### Phase 6 - Snapshot/fork and predictive placement

- baseline environment snapshots;
- one baseline to many candidates;
- interactive reproduction environments;
- predictive scheduling only if empirical data proves value over deterministic rules.

## Consequences

### Positive

- architecture no longer conflates CI orchestrators with raw compute;
- one vendor can safely occupy multiple roles;
- RunDiff can support mature customer CI without duplicating it;
- managed compute remains independently replaceable;
- runner vendors do not require one-off top-level integrations;
- parallelism becomes explicit for both evidence and billing;
- pricing can move away from misleading wall-clock minutes;
- Behavioral Review remains useful in high-volume AI workflows;
- capability-based placement can improve from empirical data;
- Performance claims have an explicit confidence model;
- Deep evidence has a clear controlled-infrastructure home;
- snapshots and one-baseline-many-candidates fit naturally.

### Costs

- Execution Plan is more complex than a flat provider field;
- capability discovery must be maintained;
- orchestration bridges need provider-specific lifecycle logic;
- parallelism and metering require careful accounting;
- managed provider routing expands the test matrix;
- confidence gating requires calibration data;
- repository history creates additional operational state.

## Non-goals

This RFC does not:

- commit to one permanent managed compute vendor;
- commit to exact Review Credit conversion rates;
- claim Deep support on any third-party provider without proof;
- require integrating every CI or runner vendor;
- require Firecracker for the first managed execution;
- make provider pricing a product contract;
- require ML/AI for placement;
- replace the portable Request / Result boundary;
- replace RFC 0006's evidence-provider model;
- turn RunDiff into a generic CI platform.

## Open questions

1. What exact ExecutionPlan schema belongs in control-plane storage?
2. Which fields, if any, should become part of the portable executor request?
3. Which direct compute candidate should be benchmarked first: Cloudflare, E2B, Vercel Sandbox, Fly Machines, Namespace, Daytona, or another system?
4. What is the first standard resource shape used for Review Credit normalization?
5. Should memory and disk have explicit Review Credit weights, or should normalization track actual provider cost behind one stable customer unit?
6. What minimum repository history is required before showing a personalized Behavioral Review estimate?
7. What default parallelism mode should Performance use for existing test suites?
8. When should RunDiff preserve external CI sharding versus rerun a controlled experiment?
9. What exact stability threshold is required before a Performance claim can block a change?
10. What capabilities define Deep v1?
11. Which snapshot/fork system should be used for the first one-baseline-many-candidates experiment?
12. Which customer CI bridge should follow GitHub Actions first?
13. What provider fallback classes are safe without changing the semantics of the experiment?
14. How should runner provenance be cryptographically or operationally trusted when importing evidence?

## Related work

- ADR 0002: Execution is the core abstraction
- ADR 0004: OpenTelemetry and W3C context
- ADR 0006: historical flat provider model, superseded by ADR 0008
- ADR 0007: Automatic placement and paired performance execution
- ADR 0008: Execution Plan is the composition boundary
- RFC 0002: Runner adapter contract
- RFC 0003: One baseline, many candidates
- RFC 0006: Portable execution and multi-source evidence
- docs/executor.md
- docs/subject-environments.md
- docs/production-runtime.md


## Cross-cutting references added by later decisions

Execution planning in this RFC assumes two additional boundaries:

- RFC 0007 defines repository-owned /rundiff.yml, Review Workload selection/discovery, GitHub browser configuration handoff, and the source-code/data boundary.
- RFC 0008 defines ownership-aware finding routing after Behavioral Diff.
- RFC 0009 defines the target managed Go Executor host runtime, lifecycle, isolation, cleanup, and evidence transport.

Canonical terminology is summarized in docs/definitions.md.

These RFCs refine adjacent product/control-plane boundaries without replacing Execution Plan as the infrastructure composition boundary.
