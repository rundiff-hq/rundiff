# RFC 0004: Compute, executor, placement, and evidence strategy

## Status

Accepted direction. Implementation is incremental.

## Context

RunDiff compares software behavior between a baseline and one or more candidates. The product therefore needs real execution compute, not only static repository analysis.

The current RunDiff repository uses GitHub Actions heavily for its own CI and dogfood proofs. That must not be confused with the customer execution architecture. The production runtime already separates the GitHub-facing Rails control plane from an isolated executor service through portable Request / Result contracts.

This RFC defines the durable model for execution providers, the Go executor role, Docker and microVM isolation, workload placement, execution stability, evidence depth, Preview versus paid managed compute, provider learning, and BYOC.

The core product question remains:

> What did this software change actually change?

## Decision summary

1. The Rails control plane owns product state, policy, GitHub integration, leases, stale guards, cancellation authority, placement policy, and publication.
2. The concrete managed executor implementation is Go. It is an execution supervisor, not "a Docker container" as a product boundary.
3. Execution Provider is the term for infrastructure that can provision compute for a RunDiff execution. Examples include GitHub Actions, Cloudflare, Namespace, RunDiff-managed fleet, and customer-hosted infrastructure.
4. A Provider Adapter is infrastructure-specific. The portable Request / Result contract remains provider-neutral.
5. Provider and runtime are separate dimensions. A provider may run Docker, a VM, Firecracker, or another isolation backend.
6. Preview uses customer GitHub Actions compute where practical. Preview therefore consumes customer Actions minutes rather than RunDiff-managed compute minutes.
7. Paid hosted plans are based on managed review volume: Review 250, Review 500, Review 1000, then Enterprise. These numbers represent managed execution minutes, not evidence quality.
8. Evidence depth is an independent axis with three product levels: Standard, Performance, and Deep.
9. Users normally select Automatic execution. RunDiff chooses a provider according to workload requirements, requested evidence depth, provider capability, stability, cost, and policy.
10. The first Placement Engine is deterministic and rule-based. RunDiff must collect placement evidence and learn from actual executions before introducing predictive models.
11. RunDiff must prefer paired baseline/candidate execution on the same execution lease over absolute cross-machine benchmarking.
12. Performance claims are confidence-gated. RunDiff measures environment noise and must suppress or downgrade claims when the observed delta is not larger than the measured noise floor.
13. Determinism is not represented internally as one magic provider score. Stability is a profile across CPU, memory, disk, network, startup, and other relevant dimensions.
14. Cloud/serverless compute is appropriate for Standard and some Performance workloads when capabilities and measured stability are sufficient. Deep evidence requires stronger host capabilities and is expected to route to RunDiff-controlled or explicitly capable customer infrastructure.
15. Firecracker is an isolation and lifecycle tool, not a determinism guarantee. It is primarily relevant to a controlled RunDiff fleet.
16. RunDiff must record provider, machine, workload, stability, cost, and failure outcomes so placement improves from empirical evidence.
17. RunDiff must not implement naive CI x 2 or CI x 3. Candidate-result reuse and baseline reuse remain strategic cost controls.
18. Deterministic evidence and behavioral diff remain the correctness path. LLM explanation stays downstream and optional.

## Terminology

### Execution Provider

An Execution Provider owns or exposes the compute substrate used for an execution.

Examples:

~~~text
github_actions
cloudflare
namespace
rundiff_fleet
customer_hosted
future providers
~~~

The implementation module that integrates one provider is a Provider Adapter.

### Runtime / isolation backend

The runtime is how customer code is isolated and executed after compute has been acquired.

Examples:

~~~text
process
Docker / OCI
VM
Firecracker microVM
containerd
Kubernetes workload
~~~

Provider and runtime are intentionally independent.

Examples:

~~~text
Provider: Cloudflare
Runtime: OCI / Docker-compatible environment

Provider: RunDiff Fleet
Runtime: Firecracker
Inner workload: Docker / OCI

Provider: Customer Hosted
Runtime: Docker, VM, Kubernetes, or another supported backend
~~~

### Evidence Provider

An Evidence Provider produces observations, not compute.

Examples include framework-native instrumentation, OpenTelemetry, cgroup/process metrics, eBPF, HTTP/network probes, and driver-native artifacts.

### Workload Profiler

The Workload Profiler describes what a repository execution requires.

### Placement Engine

The Placement Engine chooses where an execution should run.

This is a control-plane concern. The Go executor performs the assigned execution and reports evidence; it does not independently override placement policy.

## Product dimensions

RunDiff pricing and capability are intentionally not one ladder.

### Dimension 1: Review Volume

Working commercial shape:

| Plan | RunDiff-managed compute |
| --- | ---: |
| Preview | 0 managed minutes |
| Review 250 | 250 min/month |
| Review 500 | 500 min/month |
| Review 1000 | 1000 min/month |
| Enterprise | Custom |

Preview should execute in customer GitHub Actions where practical. The customer's Actions account pays for that execution. This makes the free tier useful without creating unmanaged RunDiff compute COGS.

Paid Review plans include managed execution. The plan number describes quantity only.

### Dimension 2: Evidence Depth

Evidence depth describes how deeply RunDiff observes and compares execution.

#### Standard

Standard is behavioral evidence.

Typical signals:

- build / scenario success or failure;
- exit status;
- test failures;
- application exceptions;
- stdout/stderr and logs;
- HTTP behavior;
- response and status differences;
- SQL count and fingerprints where instrumentation exists;
- OpenTelemetry spans;
- framework-native events;
- process RSS / basic CPU samples;
- artifacts.

Standard should be portable across the widest provider set.

#### Performance

Performance includes Standard plus controlled resource comparison.

Typical signals and behavior:

- paired baseline/candidate execution;
- repeated samples where appropriate;
- wall time;
- CPU time;
- peak memory and memory curve;
- disk reads/writes;
- I/O behavior;
- process/container metrics;
- environment calibration;
- measured noise;
- confidence interval or confidence class;
- performance regression thresholds.

Performance evidence must be confidence-gated.

RunDiff may report:

~~~text
BASE      182 ms
PR        195 ms
delta     +7.1%

measured environment noise: +/-1.8%
confidence: HIGH
~~~

If the delta is inside the measured noise floor, the correct output is not a regression claim:

~~~text
observed delta: +3.1%
measured environment noise: +/-4.8%
performance conclusion: INCONCLUSIVE
~~~

#### Deep

Deep includes Performance plus host and kernel evidence where available.

Potential signals:

- eBPF evidence;
- syscalls;
- socket and network-flow activity;
- TCP behavior;
- context switches;
- page faults;
- block I/O;
- scheduler/kernel latency;
- process trees;
- low-level file activity;
- flamegraphs or profiles where supported.

Deep should never silently degrade to Standard while presenting itself as Deep. Capability and provenance must be explicit.

## Provider capability model

Provider capability is discovered and measured, not assumed forever.

A current working matrix is:

| Execution Provider | Standard | Performance | Deep |
| --- | :---: | :---: | :---: |
| GitHub Actions | yes | limited / confidence-gated | no default guarantee |
| Cloudflare | yes | yes, confidence-gated | no default guarantee |
| Namespace | yes | yes | capability verification required |
| RunDiff Fleet | yes | yes | yes, target capability |
| Customer Hosted | yes | yes if capable | yes if explicitly capable |

This matrix is a current routing hypothesis, not a permanent vendor contract. Provider capabilities can change. The Placement Engine must use capability records and probes rather than hard-coded marketing assumptions.

## Preview and managed execution

### Preview

The intended free flow is:

~~~text
customer PR
  -> GitHub Actions
       -> RunDiff execution/instrumentation
       -> RunDiff evidence/result
  -> control plane
  -> GitHub Check / review
~~~

Preview has zero RunDiff-managed compute minutes. It can still provide useful Standard evidence.

Preview should not be intentionally crippled merely to force an upgrade. Paid value comes from managed compute, higher volume, stronger performance control, deeper evidence, retention, policy, and enterprise features.

### Review 250 / 500 / 1000

Paid managed Review plans should normally use automatic provider placement:

~~~text
RunDiff Control Plane
      |
      v
Workload Profiler
      |
      v
Placement Engine
      |
      +--> Cloudflare
      +--> Namespace
      +--> RunDiff Fleet
      +--> future providers
~~~

A customer buys RunDiff Review capacity, not "the Cloudflare plan" or "the Namespace plan".

Provider choice is an implementation and policy detail unless the customer explicitly needs control.

### Enterprise

Enterprise may expose additional placement policy:

- customer-hosted / BYOC first;
- region restrictions;
- private networking;
- approved provider allow-list;
- no public hosted runners;
- performance stability over cost;
- dedicated capacity;
- custom retention and evidence policy.

## Workload Profiler

The Workload Profiler should derive a requirements document before placement.

Illustrative profile:

~~~text
runtime:
  ruby: 3.4
  framework: rails

services:
  - app
  - postgres
  - redis
  - sidekiq

docker_compose: true
privileged: false
nested_docker: false
custom_networking: false

estimated:
  memory_gb: 3.2
  cpu_cores: 2
  duration_seconds: 240

evidence_depth: performance

requirements:
  paired_execution: true
  ebpf: false
  stable_cpu: preferred
~~~

The profiler can use repository configuration, Docker/Compose files, detected services, prior RunDiff history, and eventually explicit customer policy.

## Placement Engine

### Version 1: deterministic rules

Do not begin with ML or an LLM scheduler.

The first version should be simple, auditable, and explainable.

Conceptually:

~~~text
if evidence_depth == deep:
  choose explicitly Deep-capable provider
else if workload requires unsupported privileged/network features:
  exclude incompatible providers
else:
  choose cheapest provider that satisfies
    capability
    resource requirements
    region/policy
    current stability threshold
~~~

Selection can consider:

- requested evidence depth;
- required CPU/RAM/disk;
- number and type of services;
- Docker Compose topology;
- privileged requirements;
- networking requirements;
- nested virtualization/container requirements;
- architecture;
- expected duration;
- cold-start sensitivity;
- cache locality;
- provider availability;
- measured stability;
- historical success for this workload class;
- expected cost;
- organization policy.

### Placement explanation

Placement decisions should be inspectable.

Example:

~~~text
Cloudflare
  compatible: yes
  resources: sufficient
  deep evidence: not requested
  expected cost: low
  recent stability: acceptable

Namespace
  compatible: yes
  expected cost: higher

RunDiff Fleet
  compatible: yes
  deep-capable: yes
  not required

selected: Cloudflare
~~~

### Fallback

Provider failure can trigger a policy-controlled fallback.

Example:

~~~text
Cloudflare selected
  -> unsupported network behavior / OOM / infra failure
  -> retry on Namespace
  -> success
  -> record placement outcome
~~~

A future execution of the same repository should use that history rather than repeat the same avoidable placement failure.

## Placement learning

RunDiff should collect empirical placement evidence from every managed execution.

Useful dimensions include:

- provider;
- region;
- machine / shape;
- CPU architecture and observable CPU identity when available;
- repository/workload fingerprint;
- languages and frameworks;
- service count and service classes;
- container count;
- requested evidence depth;
- estimated versus actual peak RAM;
- estimated versus actual CPU;
- startup/bootstrap/build time;
- baseline time;
- candidate time;
- total execution time;
- infra failure type;
- OOM events;
- retries and fallback;
- environment stability profile;
- cache hit rate;
- evidence bytes;
- network bytes when available;
- provider-reported or estimated cost.

The system should learn at two levels:

1. workload-class history, for example Rails + Postgres + Redis;
2. repository-specific history.

Repository-specific history is especially valuable. After repeated reviews, RunDiff can know the normal resource envelope and bootstrap behavior of that exact repository.

Predictive models may be introduced only after this dataset exists and only where they outperform transparent rules.

## Determinism and execution stability

### Do not model determinism as provider marketing

Cloud execution is not perfectly deterministic. CPU host model, noisy neighbors, disk contention, network, placement, thermal behavior, cache state, and cold starts can all introduce variation.

RunDiff should therefore describe a measured Execution Stability Profile, not claim that one provider has a permanent global determinism coefficient.

A useful profile can contain:

~~~text
CPU       0.991
Memory    0.987
Disk      0.962
Network   0.814
Startup   0.944
~~~

A single aggregate value may exist for scheduling, but user-facing performance conclusions should retain the relevant dimensions.

### Calibration

Before or alongside Performance executions, the executor can run a short calibration suite.

Candidate probes include:

- integer / hashing CPU workload;
- compression workload;
- memory bandwidth;
- local disk sequential I/O;
- local disk random I/O;
- process spawn;
- container startup;
- optional network RTT when network performance is part of the claim.

A working stability metric for one dimension can be:

~~~text
median = median(samples)

deviation[i] =
  abs(sample[i] - median) / median

noise95 =
  percentile(deviation, 95)

stability95 =
  1 - noise95
~~~

This formula is an implementation hypothesis, not yet a public contract. The important contract is that RunDiff measures noise and records how the confidence conclusion was produced.

### Paired execution over absolute benchmarking

The strongest practical control is not "use the same physical machine forever".

It is:

> Run baseline and candidate under the same execution lease and as close to the same conditions as possible.

Basic sequence:

~~~text
acquire worker
  -> calibrate
  -> BASE
  -> PR
  -> compare
  -> release worker
~~~

For higher-confidence Performance reviews, interleave samples:

~~~text
BASE
PR
PR
BASE
BASE
PR
~~~

or another balanced schedule.

This reduces the impact of host-to-host variation because baseline and candidate share the same host, runtime, cache policy, region, and approximate time window.

A slow worker can still produce a useful relative result if it affects both subjects similarly.

## Reference / golden execution

RunDiff may maintain a high-control reference tier for validation and high-confidence benchmarks.

A reference host can target:

- dedicated bare metal;
- fixed CPU model;
- fixed RAM configuration;
- local NVMe;
- fixed kernel and OS image;
- no unrelated workloads;
- fixed CPU governor;
- optional CPU pinning;
- optional NUMA pinning;
- minimized background services;
- explicit SMT / turbo policy;
- prefetched dependencies;
- fixed container images;
- fixed random seeds;
- fixed database fixtures;
- external network disabled or separately measured.

The reference tier should still measure its own stability. It is not assigned 1.000 by definition.

This tier is appropriate for RunDiff's own calibration, release benchmarks, performance-regression confirmation, and high-confidence customer review modes. It is not required for every normal PR.

## Executor role

### The executor is a supervisor

The concrete current direction is a Go executor.

The durable architectural role is:

~~~text
RunDiff Executor
  -> acquire / receive execution environment
  -> prepare repository
  -> bootstrap
  -> build
  -> start subjects
  -> readiness
  -> execute scenario
  -> collect evidence
  -> teardown
  -> return portable Result
~~~

It coordinates foreign processes and Linux primitives. It is not a CPU-bound data plane.

### Deployment is not the abstraction

The executor may be delivered as:

- a binary;
- a systemd service;
- an OCI image;
- a Kubernetes DaemonSet;
- another host agent form.

For a controlled RunDiff worker, the preferred direction is a small host-level daemon rather than making "executor inside Docker" a hard invariant. Host-level execution gives the supervisor clean access to cgroups, namespaces, KVM, network namespaces, block devices, eBPF, and host metrics.

A provider can still require the executor itself to run inside a container. That is a provider-specific deployment constraint, not the core model.

## Docker, VMs, and Firecracker

Docker remains an important workload runtime. It is not the entire executor architecture.

For generic managed jobs:

~~~text
Execution Provider
  -> worker / VM
       -> RunDiff Executor
            -> Docker / OCI workloads
~~~

For a controlled high-isolation fleet:

~~~text
RunDiff Control Plane
  -> Placement Engine
       -> RunDiff Fleet host
            -> Go Executor
                 -> Firecracker microVM
                      -> Docker / OCI
                           -> app
                           -> postgres
                           -> redis
                           -> tests
~~~

Firecracker is useful for strong tenant isolation, fast disposable VM lifecycle, clean execution boundaries, resource boundaries, and controlled fleet security.

Firecracker does not remove noisy-neighbor effects from the physical host and does not make a benchmark deterministic by itself.

## Provider roles

### GitHub Actions

Primary near-term role:

- Preview execution;
- customer-funded compute;
- easy adoption;
- functional and Standard evidence;
- limited Performance evidence when measured confidence is sufficient.

GitHub-hosted runner identity should not be treated as a stable physical benchmark machine.

### Cloudflare

Primary candidate role:

- managed burst compute for simple-to-moderate workloads;
- Standard evidence;
- Performance evidence when paired execution and measured stability meet the threshold.

Provider restrictions around privileged behavior, networking, nested execution, or host visibility must be capability-detected. Cloudflare should not be the Deep evidence contract.

Review 250 / 500 / 1000 may route substantial eligible work to Cloudflare without making Cloudflare visible in the commercial plan name.

### Namespace

Primary candidate role:

- CI-oriented managed compute;
- larger or more complex workloads;
- Standard and Performance execution;
- fallback when another provider cannot satisfy topology or capacity requirements.

Deep capability must be explicitly verified before being promised.

### RunDiff Fleet

Primary role:

- controlled Performance;
- Deep evidence;
- host metrics and eBPF;
- strong isolation;
- reference execution;
- workloads that external providers cannot satisfy.

The RunDiff Fleet can use dedicated hosts and Firecracker or another suitable isolation backend.

### Customer Hosted / BYOC

Primary role:

- enterprise;
- private networks;
- data residency;
- provider restrictions;
- controlled performance;
- Deep evidence where the customer grants required host capabilities.

### exe.dev and similar ephemeral VM products

These services are interesting provider candidates, but do not need to be primary production placement targets initially.

A particularly strong future integration is interactive reproduction:

~~~text
RunDiff failure
  -> Open reproduction environment
       -> disposable VM
       -> exact revision + artifacts + scenario context
       -> SSH / agent debugging
~~~

This can be valuable even when the provider is not used for the original benchmark execution.

### Blacksmith and Actions-compatible providers

Actions-compatible compute remains useful for organizations already invested in GitHub Actions or for BYOC-style deployments.

It should not become the architectural foundation of managed RunDiff because RunDiff already owns its own durable execution scheduler, leases, cancellation, and provider boundary.

## Do not run everything A/B

RunDiff is not CI x 2.

### Candidate-only by default

Examples:

- lint;
- formatting;
- static type checks;
- most static security analysis;
- other checks where baseline execution adds no behavioral meaning.

### A/B by default when relevant

Examples:

- HTTP/API scenarios;
- browser/user flows;
- selected tests whose runtime evidence is useful;
- SQL/query behavior;
- background jobs;
- external side effects;
- latency;
- memory/resource behavior;
- network behavior;
- runtime traces/profiles;
- file/process behavior.

The execution planner should make this classification explicit.

## Candidate and baseline reuse

If the customer already executed an equivalent candidate check in CI, RunDiff should eventually import that evidence rather than rerun it when identity and provenance are strong enough.

Reuse requires at least:

- exact commit SHA;
- exact scenario/test identity;
- compatible runtime/environment profile;
- compatible instrumentation/evidence contract;
- trustworthy provenance.

A green exit code alone is not enough.

Baseline execution should also be reusable across candidates when the identity includes all relevant environment and fixture inputs.

Potential baseline cache identity:

~~~text
baseline commit SHA
scenario identity
subject environment
runtime/toolchain identity
instrumentation profile
fixture/database identity
relevant secrets/emulator profile
~~~

RunDiff must never silently reuse a baseline captured under an incompatible environment.

## Customer UX

Most users should not choose a provider.

Default:

~~~text
Execution
  Automatic - recommended
~~~

The product-facing configuration is instead:

~~~text
Review volume
  Preview | 250 | 500 | 1000 | Enterprise

Evidence depth
  Standard | Performance | Deep
~~~

Advanced or Enterprise users may optionally choose or constrain execution:

~~~text
Execution policy
  Automatic
  RunDiff managed only
  GitHub Actions
  approved provider list
  Customer Hosted
~~~

This separation prevents implementation detail from leaking into the pricing model.

## Cost model

The important distinction is:

~~~text
customer GitHub bill
!=
RunDiff infrastructure cost
~~~

Preview intentionally uses customer GitHub Actions where practical.

Paid Review plans consume managed execution minutes and RunDiff pays the selected managed provider.

Real cost depends on clone/bootstrap, dependency caching, baseline reuse, candidate-result reuse, database preparation, scenario count and duration, CPU/RAM class, browser usage, evidence depth, evidence/artifact size, retries/fallback, provider availability, and idle capacity.

Public provider prices are inputs to the Placement Engine and unit-economics work, not durable architecture.

RunDiff should not sell "Cloudflare minutes" or "Namespace minutes". It should sell managed Review capacity and evidence capability.

## Usage metering

Operational metering is outside the portable behavioral Result contract.

It should answer:

~~~text
cost per Behavioral Review
cost per repository/customer
cost by evidence depth
gross margin by product plan
compute avoided through reuse
provider success/failure rate
provider stability by workload class
placement accuracy
~~~

Metering must never persist repository capabilities, credentials, or customer secrets.

## LLM boundary

The core path remains:

~~~text
instrumentation
  -> structured evidence
  -> deterministic behavioral diff
  -> policy
  -> optional LLM explanation
  -> human / agent review
~~~

An LLM is not required to decide whether deterministic evidence changed, to calculate environment noise, or to choose an execution provider in the initial Placement Engine.

## Suggested implementation sequence

### Phase 1

- keep GitHub Actions Preview path;
- introduce explicit ExecutionProvider capability model;
- add WorkloadProfile;
- add rule-based PlacementEngine;
- collect placement/metering evidence;
- route eligible paid executions to one managed provider;
- retain provider fallback.

### Phase 2

- add second managed provider;
- add calibration suite;
- implement Performance confidence gating;
- implement same-lease paired execution and interleaving;
- build repository-specific placement history.

### Phase 3

- introduce controlled RunDiff Fleet;
- move Go executor to host-supervisor form where appropriate;
- add stronger cgroup/process signals;
- introduce Firecracker or another microVM backend if justified by isolation and lifecycle tests.

### Phase 4

- Deep evidence on controlled hosts;
- eBPF sensors;
- reference execution tier;
- richer BYOC;
- interactive reproduction integrations;
- predictive placement only if data shows a clear advantage over deterministic rules.

## Consequences

### Positive

- Preview can be useful without RunDiff-funded compute.
- Paid plans have clean unit economics based on managed minutes.
- Evidence quality is no longer accidentally coupled to plan volume.
- Provider competition remains available.
- Provider failures can be learned from instead of repeatedly rediscovered.
- RunDiff can choose the cheapest compatible environment without exposing infrastructure complexity to most users.
- Same-lease paired execution improves performance comparison even on variable cloud hardware.
- Deep evidence has an explicit home on controlled infrastructure.
- Firecracker can be adopted for security without pretending it solves hardware noise.
- BYOC remains compatible with the same Request / Result boundary.

### Costs

- placement, capability discovery, and fallback become first-class systems;
- RunDiff must collect and retain operational execution metadata;
- Performance claims need calibration and confidence logic;
- provider-specific incompatibilities need clear reason codes;
- managed fleet operation remains necessary for the strongest evidence depth;
- provider routing increases testing surface area.

## Open questions

1. Which managed provider should be the first production target for paid Review plans?
2. What exact capability schema should every Provider Adapter expose?
3. What stability thresholds should gate Performance conclusions?
4. What minimum sample count and interleaving strategy should Performance use by default?
5. Which workloads should automatically escalate from Cloudflare-class compute to Namespace-class or RunDiff Fleet?
6. What exact host capabilities are required for the first Deep profile?
7. When does Firecracker provide enough isolation/lifecycle value to justify operating it?
8. What exact policy should govern automatic provider fallback versus immediate INFRA_FAILURE?
9. Which repository-history fields are safe and useful for long-term placement learning?
10. Which interactive reproduction provider, if any, should be integrated first?

## Related work

- ADR 0002: Execution is the core abstraction
- ADR 0004: OpenTelemetry and W3C context
- ADR 0006: Separate execution provider, runtime, and evidence depth
- ADR 0007: Automatic placement and paired performance execution
- RFC 0002: Runner adapter contract
- RFC 0003: One baseline, many candidates
- RFC 0006: Portable execution and multi-source evidence
- docs/executor.md
- docs/production-runtime.md
- docs/subject-environments.md
- #76 managed executor strategy
- #77 provider benchmarks and cost model
- #78 candidate reuse and A/B execution policy
- #79 eBPF/runtime evidence boundary
- #80 usage metering
- #81 customer BYOC providers
- #82 managed disposable executor prototype
- #83 executor-provider configuration
- #84 commercial pricing assumptions
- #85 RFC tracking issue
