# RFC 0013: Boxd as a forkable Compute Provider

## Status

Proposed research direction.

Captured: 2026-09-29

Tracking issue: #210

This RFC is append-only research material. It does not replace RFC 0004 or RFC 0009 and does not make Boxd a required RunDiff dependency.

## Why this RFC exists

RFC 0004 already separates Execution Orchestrator, Compute Provider, Runner Backend, Runtime / isolation backend, Subject Environment, Evidence Provider, and Placement Engine.

Boxd is interesting specifically because it exposes a programmable full-VM substrate with a first-class fork operation that copies a running machine's memory and disk state. That maps naturally to RunDiff's strategic requirement to avoid rebuilding equivalent baseline/candidate environments from zero.

The useful question is not:

> Should RunDiff move to Boxd?

It is:

> Can a forkable VM Compute Provider reduce preparation cost for paired execution while preserving RunDiff's existing correctness, evidence, cleanup, and placement boundaries?

## External signal

Verified against Boxd public documentation on 2026-09-29:

- full Ubuntu 24.04 KVM VMs;
- documented cold boot under 10 ms;
- running-machine fork copies memory + disk + running processes;
- documented fork latency is roughly 100-200 ms;
- machine lifecycle is scriptable through the boxd CLI and JSON output;
- a gRPC API exists underneath the CLI;
- Python and TypeScript SDKs exist;
- hibernated machines bill disk only;
- the default managed machine is 2 vCPU / 8 GiB RAM / 100 GiB disk;
- Boxd also advertises self-host/BYOC for custom plans.

Sources:

- https://boxd.sh/
- https://boxd.sh/features/forking/
- https://boxd.sh/pricing
- https://boxd.sh/faq/
- https://boxd.sh/blog/sandboxes/
- https://boxd.sh/blog/boxd-vs-exe-dev

Vendor claims must be re-verified before a production placement decision.

## Architectural role

Boxd is a candidate implementation of the existing RFC 0004 Compute Provider role.

~~~text
RunDiff Rails Control Plane
        |
        v
Placement Engine
        |
        v
Execution Plan
        |
        +--> compute.provider = boxd
        |
        v
RunDiff Go Executor
        |
        +--> Subject Environment
        +--> Evidence Providers
        |
        v
Portable Result
        |
        v
Behavioral Diff
~~~

Boxd is not:

- RunDiff Execution;
- the Rails control plane;
- an Execution Orchestrator;
- a Subject Environment;
- an Evidence Provider;
- the Behavioral Diff engine;
- a replacement for the controlled-host / Firecracker direction.

The same workload must remain placeable on another compatible Compute Provider.

## Primary hypothesis

A preconfigured running golden VM can amortize expensive environment preparation across a paired baseline/candidate execution.

Target shape:

~~~text
golden VM
  app toolchain installed
  dependencies warm
  database/service topology ready
  RunDiff executor available
        |
        +---- fork ----> baseline VM
        |
        +---- fork ----> candidate VM
                              |
                       same scenario
                              |
                         evidence
                              |
                      Behavioral Diff
~~~

The fork operation is only an infrastructure optimization. It must not change Result v1 semantics or make VM state itself authoritative product evidence.

## Why this may matter economically

RunDiff must not become naive CI x2.

For a typical repository, setup can dominate the actual behavioral scenario:

~~~text
clone
-> install language/runtime dependencies
-> restore package dependencies
-> start PostgreSQL/Redis/other services
-> migrate/seed
-> warm application/runtime
-> run scenario
~~~

If a trusted golden environment can be prepared once and forked in roughly hundreds of milliseconds, baseline and candidate can begin from the same infrastructure moment while only paying for their divergent execution.

This is especially relevant to:

- one-baseline-many-candidates;
- AI-generated candidate evaluation;
- repeated paired Performance samples;
- interactive reproduction;
- expensive dependency/service topology.

The expected benefit must be measured. Fork speed alone is not evidence that end-to-end RunDiff execution is faster or cheaper.

## Correctness constraints

### Exact source identity

A forked machine does not remove the requirement to execute exact baseline and candidate source identities.

The executor must still record and verify:

- repository identity;
- baseline revision;
- candidate revision;
- execution id;
- attempt number;
- subject/environment provenance.

### Isolated mutable state

Forking a warm database or service topology is useful only if post-fork writes cannot leak across baseline and candidate.

The live proof must verify that each child has independent mutable state.

A successful VM fork does not automatically prove application-state comparability.

### Same-scenario semantics

Baseline and candidate must still execute the same RunDiff scenario under the same portable contract.

Provider-specific launch mechanics must stay below the scenario/evidence layer.

### Failure taxonomy

Provider lifecycle failures must remain distinguishable from workload failures.

Examples:

~~~text
boxd CLI/API unavailable     -> PROVIDER_INFRA_FAILURE
fork rejected                -> PROVIDER_INFRA_FAILURE
requested capability absent  -> CAPABILITY_MISMATCH
customer command exits 1     -> WORKLOAD_FAILURE or phase-specific failure
scenario regression          -> normal Behavioral Diff finding
~~~

A non-zero customer command exit must not be mislabeled as provider transport failure merely because it was launched through boxd machine exec.

### Cleanup

Both forked children must be removed on:

- success;
- baseline failure;
- candidate failure;
- cancellation;
- timeout;
- partial provisioning failure.

If the first child is created and the second fork fails, the first child must be removed.

The Resource Journal remains the eventual durable cleanup authority when this progresses beyond the spike.

## Integration transport

The repository-safe Slice A initially used the Boxd CLI because it was a small,
dependency-light way to prove the Compute Provider seam.

A live GitHub Actions proof on 2026-09-29 found an important headless-auth
constraint: Boxd CLI v0.2.20 did not consume the repository's
`BOXD_API_KEY` for an external CI session. A machine command fell back to the
interactive browser login flow and waited for confirmation. The secret was
present in the job; the CLI session was not authenticated by it.

The live spike therefore uses the official TypeScript SDK behind a tiny
JSON stdin/stdout bridge:

~~~text
Go compute.Provider
        |
        v
structured JSON request
        |
        v
pinned @boxd-sh/sdk bridge
        |
        v
Boxd gRPC API
~~~

The SDK explicitly supports `BOXD_API_KEY` and exchanges it for a short-lived
session token. Its machine API exposes create, fork, exec, delete, and
wait-until-ready operations, including preservation of the remote command exit
code.

The old CLI adapter remains useful as a repository-safe contract/reference, but
it is not the headless live transport.

The bridge is intentionally below `compute.Provider`. It must:

1. never construct a customer shell command;
2. pass argv as a structured string array;
3. keep non-zero remote workload exits as `ExecResult`, not provider errors;
4. map SDK/auth/network failures to provider infrastructure errors;
5. pin the SDK version for the spike.

The first bridge starts one short-lived SDK process per provider operation. That
is acceptable for the bounded live proof, but it is not the desired production
shape: the SDK documents an API-key exchange rate limit and recommends sharing
a session token for fleets behind one NAT. A production Boxd provider should
use a long-lived SDK bridge/client or a future supported native Go client/proto
without changing the Compute Provider contract.

## Candidate internal contract

Illustrative only:

~~~go
type Provider interface {
    Fork(ctx context.Context, sourceName, childName string) (Machine, error)
    Exec(ctx context.Context, machine Machine, argv []string) (ExecResult, error)
    Remove(ctx context.Context, machine Machine) error
}
~~~

This is an internal implementation seam, not a public wire contract.

The abstraction should remain intentionally small until a real second provider or controlled-fleet backend proves what belongs in it.

## Golden machine lifecycle

A golden machine is trusted RunDiff infrastructure state, not customer mutable output.

Candidate lifecycle:

~~~text
create/update golden
-> install executor/toolchain
-> prepare trusted immutable dependency layers
-> start reusable services where safe
-> healthcheck
-> mark golden ready

execution
-> fork baseline
-> fork candidate
-> apply exact source identities
-> prepare role-specific mutable state
-> execute
-> collect
-> remove children
~~~

Do not blindly snapshot secrets, short-lived repository credentials, execution tokens, or customer-specific mutable data into the golden parent.

## Placement implications

A future capability record may include properties such as:

~~~text
compute.provider.boxd
isolation.kvm
lifecycle.fork_running_state
lifecycle.hibernate
network.public_ipv4
runtime.docker
runtime.systemd
region.eu
~~~

These names are illustrative and are not a schema proposal.

Placement must still consider:

- data residency;
- architecture;
- required CPU/memory;
- Docker/Compose needs;
- networking;
- privileged operations;
- requested Evidence Depth;
- measured noise;
- cost;
- provider availability.

## Evidence Depth

Boxd's KVM boundary is useful for tenant isolation but does not automatically provide RunDiff Deep evidence.

Standard evidence should be feasible.

Performance evidence requires repeated measurement of environmental noise and confidence gating.

Deep evidence may require host privileges or sensor access that a managed external provider does not expose.

Unsupported capabilities must be absent or explicitly degraded. RunDiff must never retain the Deep label after losing required evidence.

## Security

The provider adapter must not receive:

- GitHub App private key;
- webhook secret;
- broad organization credentials;
- customer long-lived credentials.

Repository access should continue to use the existing short-lived repository-scoped capability after exact attempt claim.

For untrusted customer execution, the live spike should prefer Boxd's isolated-machine mode when compatible with the required workflow and should verify its actual credential/network semantics rather than assume them from marketing text.

## Live proof

Tracking issue #210 defines the live acceptance.

Minimum proof:

1. prepare one trusted golden machine;
2. install/build the current RunDiff Go executor;
3. fork baseline and candidate;
4. apply exact source revisions;
5. run the same existing RunDiff scenario;
6. collect existing portable evidence;
7. produce a real Behavioral Diff;
8. clean up both children;
9. record timings and actual provider cost.

Measurements:

~~~text
golden preparation wall time
fork baseline latency
fork candidate latency
source materialization latency
role-specific state preparation latency
scenario wall time
total execution wall time
bytes/disk divergence if available
provider cost
~~~

Compare against the current GitHub-hosted execution path using the same subject/scenario where practical.

## Promotion gate

One successful demo is insufficient.

Boxd should become a selectable managed placement target only after:

- repeated live executions;
- measured failure/cleanup behavior;
- comparable evidence correctness;
- provider capability detection;
- provider fallback;
- cost data;
- explicit credential handling;
- cancellation proof;
- no regression in exact-attempt fencing.

It should become a default placement choice only from empirical placement data, not architectural enthusiasm.

## Non-goals

This RFC does not:

- select Boxd as the default managed backend;
- make Boxd part of Request v1 / Result v1;
- replace the Go executor;
- replace subject environments;
- replace Firecracker/controlled-host research;
- claim deterministic Performance evidence;
- define a public Compute Provider plugin API;
- require direct gRPC integration;
- require customer repositories to contain Boxd credentials.

## Relationship to existing work

- RFC 0003: one baseline, many candidates
- RFC 0004: execution planning, compute, placement, and evidence strategy
- RFC 0006: portable execution and multi-source evidence
- RFC 0009: managed Go executor host runtime
- RFC 0011: control-plane/executor protocol
- docs/executor.md
- docs/customer-code-execution-boundary.md
- docs/subject-environments.md
- docs/execution-leases.md

## Consolidation rule

Treat Boxd as a measured provider experiment.

Promote only provider-independent conclusions into canonical architecture unless repeated production evidence justifies a Boxd-specific optimization.
