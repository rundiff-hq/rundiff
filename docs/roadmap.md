# Roadmap

## Current product vertical slice - External repository -> first review

The current product goal is to make the already-working behavioral engine visible as a complete customer workflow:

```text
open /onboarding
  -> install public RunDiff GitHub App
  -> grant access to one Rails repository
  -> add candidate-only rundiff.yml
  -> open or update a pull request
  -> RunDiff executes exact baseline + candidate in isolated state
  -> GitHub receives a Behavioral Review
```

Repository-side target configuration:

```yaml
version: 1
scenario:
  path: /orders/42
subject:
  persistence: auto
```

The customer should not need a RunDiff gem, GitHub Action, middleware, initializer, Docker setup, executor configuration, or operator assistance.

### Already proven

- exact baseline/candidate Git worktrees
- isolated Rails + PostgreSQL and Rails + SQLite subject environments
- runtime evidence collection and deterministic Behavioral Diff
- remote executor boundary
- GitHub Check + durable PR feedback
- customer-like sandbox BLOCK and ALLOW proofs
- hosted onboarding surface
- production-role deployment tooling
- immutable production image publishing
- hermetic full production topology lab
- production identity and proof verification tooling
- fail-fast Production Lab budgets and timeout diagnostics

### Remaining production gate

1. Complete the first real infrastructure apply from #92.
2. Complete the live external identity cutover from #121.
3. Run #75 from a GitHub account or organization outside `rundiff-hq`.
4. On one external PR, prove GitHub-originated `opened -> BLOCK`, push the behavioral fix, then prove `synchronize -> ALLOW`.
5. Run Production Proof v2 and retain GitHub-confirmed delivery GUIDs, exact execution/Check/comment identities, both candidate SHAs, and install-to-first-review elapsed time.

Definition of done: a new external Rails repository can go from **Install RunDiff** to its first Behavioral Review without RunDiff operator intervention.

Timing sampling hardening from #103/#137 remains important, but it is not allowed to hide or delay this end-to-end product proof.

## Vertical Slice 1.0 - Cloudflare-native production proof

Selected hosted implementation:

~~~text
React + Hono Worker
  + D1
  + Cloudflare Workflows
  + R2
        |
        v
GitHub Actions
  -> RunDiff Executor
~~~

Current proof state:

- [x] Cloudflare local spike: Worker + D1 + Workflow + Result lifecycle.
- [x] Durable D1 Behavioral Review + React Review Detail.
- [x] GitHub webhook signature verification and delivery deduplication.
- [x] Exact repository/PR/base/head identity semantics.
- [x] Current-candidate authority, supersede/stale guards, attempt/result identity, and finalization fencing.
- [x] GitHub Actions portable Request/Result bridge.
- [x] Remote Worker + D1 + Workflow + R2 deployment.
- [x] Remote BLOCK and ALLOW synthetic bridge proofs.
- [x] Duplicate Result idempotency, conflicting Result rejection, executor failure, and timeout -> INFRA_FAILURE.
- [ ] Resolve GitHub Actions account billing/spending block so hosted jobs can start.
- [ ] Configure deployed Worker with production GitHub App credentials and proof scenario.
- [ ] Install the production App on an external demo repository.
- [ ] Real `pull_request/opened` -> deliberate regression -> BLOCK.
- [ ] Push fix to the same PR -> `synchronize` -> ALLOW.
- [ ] Retain Production Proof v2 identities and actual Cloudflare/GitHub cost.
- [ ] Verify authoritative domain and bind a custom domain after the external proof; this is not required to validate the Worker lifecycle itself.

Not required for VS1: Durable Objects, Queues, Containers executor, Rails parity, PostgreSQL, Temporal, Performance/Deep evidence, billing, RCA/causal graph.

Rails remains a reference/fallback implementation rather than the hosted-v1 deployment target.

See ADR 0016 and RFC 0011.

## Analysis depth guardrail

RunDiff deliberately stops short of building a full investigation/ontology platform before the first production Behavioral Review proof.

The near-term analysis depth is intentionally limited to:

~~~text
stable Rule ID
+ Finding facets
+ stable Finding fingerprint
+ explicit baseline/candidate evidence references
~~~

After that, analysis-model work is paused until the product proves a real need.

The following are **consciously deferred**, not forgotten:

- causal graph execution and persistence;
- a general RCA engine;
- rich Diagnosis entities beyond the small deterministic runtime classifications already present;
- hypothesis -> confirmation workflows;
- SARIF export/import;
- ontology database/editor;
- user-configurable taxonomy authoring;
- a broad multi-dimensional confidence framework;
- automatic AI root-cause analysis;
- IEC 62740 workflow/conformance work;
- graph ranking of causes/contributing factors;
- generic cross-finding causal inference.

These capabilities remain architecturally reserved by RFC 0010.

### Re-entry triggers

Do not resume the deferred depth merely because it is technically interesting.

Resume a deeper analysis capability only when at least one concrete product trigger exists, for example:

1. the external production `BLOCK -> fix -> ALLOW` proof is complete;
2. the first Control Panel needs a specific deeper concept to explain a real review;
3. Performance/Deep evidence creates multiple findings that users cannot understand without relations;
4. ownership routing needs deduplication/identity beyond the current fingerprint;
5. agents need machine-readable investigation state to perform a real repair loop;
6. a customer/export integration creates a concrete SARIF or RCA requirement.

Until then, work on analysis taxonomy must not delay the production control plane, GitHub Actions execution bridge, Review Workload configuration, or second-provider proof.

## Capability roadmap

## Slice 0 - Bootstrap
Rails shell, docs, portable behavioral diff, result/execution schemas.

## Slice 1 - Real Rails evidence
Run baseline/candidate Rails subjects, capture wall time, SQL count, jobs, fake email side effects, persist executions/findings.

## Slice 2 - GitHub-native feedback
GitHub App, stable Check Run, one updateable PR comment, `external_id`, JSON result artifact, source annotations.

## Slice 3 - Playwright
Run customer or first-party scenarios, collect Playwright Trace, correlate browser requests to backend execution.

## Slice 4 - OpenTelemetry
Trace/log ingestion, execution correlation, causal drill-down.

## Slice 5 - More surfaces
CLI/process, Maestro/agent-device, Cypress/Capybara, k6, service emulation, optional session replay.

## Slice 6 - Agent loop
MCP, rerun/investigate tools, continuation policy, automated repair feedback.


## Strategic product/execution roadmap

The slices above describe the original capability evolution. The accepted architecture now adds the following product-shaped sequence.

### Slice 7 - Repository-owned Review Workload

Goal: stop treating full CI as the default RunDiff workload.

Deliver:

- canonical /rundiff.yml;
- Review Workload model;
- explicit / changed / related / full selection;
- RSpec/Minitest discovery first;
- workload catalog metadata;
- control-panel visual editor;
- source-code discovery inside execution boundary.

Success:

> A customer can choose what RunDiff reviews without copying their whole CI pipeline.

See RFC 0007.

### Slice 8 - GitHub configuration handoff

Deliver:

- read-only repository Contents permission;
- configuration preview in control panel;
- Open configuration on GitHub CTA;
- GitHub-native branch/commit/PR confirmation;
- existing-config/update flow;
- no manual YAML copy/paste on the happy path.

Success:

> RunDiff config is created through normal Git review without giving the main App permanent repository-content write access.

See ADR 0011 and RFC 0007.

### Slice 9 - Managed placement and Review Credits

Deliver:

- Workload Profile;
- Execution Plan;
- capability catalog;
- deterministic Placement Engine;
- first direct managed compute adapter;
- usage telemetry;
- Review Credit prototype;
- estimated Behavioral Reviews.

Success:

> Paid RunDiff can place compatible workloads automatically and explain both placement and expected usage.

See RFC 0004 and docs/pricing.md.

### Slice 10 - Managed Go Executor

Deliver:

- standalone Go executor;
- explicit lifecycle phases;
- process supervision;
- cgroup v2 resource accounting on controlled Linux;
- Resource Journal;
- two-phase cleanup with sweeper;
- cancellation/supersede termination;
- OTLP/local evidence bus foundation.

Success:

> A failed or cancelled customer execution cannot leave unmanaged process/resource state behind.

See RFC 0009.

### Slice 11 - Performance confidence

Deliver:

- calibration suite;
- Execution Stability Profile;
- paired same-lease BASE/PR;
- controlled/frozen parallelism;
- repeated/interleaved sampling;
- confidence-gated result semantics;
- INCONCLUSIVE when signal does not exceed measured noise.

Success:

> RunDiff does not claim a performance regression that the execution environment cannot distinguish from noise.

See RFC 0004.

### Slice 12 - Multi-provider and external orchestrator bridges

Deliver based on customer demand:

- second managed compute provider;
- GitHub Actions Preview path;
- Buildkite bridge candidate;
- later GitLab/CircleCI bridges where justified;
- runner provenance;
- candidate evidence import;
- provider fallback learning.

Success:

> RunDiff can use customer CI or managed compute without changing the Behavioral Review contract.

See RFC 0004.

### Slice 13 - Ownership-aware routing

Deliver:

- CODEOWNERS resolver;
- ownership reasons;
- ownership display in RunDiff review;
- Slack + generic webhook first external adapters;
- severity/confidence routing;
- INFRA_FAILURE operational routing;
- deduplication.

Success:

> A meaningful regression reaches the people who own the affected behavior without broadcasting every finding.

See RFC 0008.

### Slice 14 - Controlled fleet / Deep

Deliver:

- RunDiff Fleet;
- stronger namespaces/isolation;
- optional Firecracker runtime;
- eBPF/out-of-process sensors;
- Deep Evidence capability;
- reference execution tier.

Success:

> RunDiff can provide host/kernel evidence on infrastructure whose capabilities it actually controls.

See RFC 0004, RFC 0006, and RFC 0009.

### Slice 15 - Snapshot/fork and high-volume agent workflows

Deliver:

- prepared environment snapshots where safe;
- one baseline -> many candidates;
- candidate fan-out;
- interactive reproduction;
- repository-specific placement learning;
- agent action routing.

Success:

> RunDiff remains economical and useful when AI systems generate many candidate changes per human decision.

See RFC 0003, RFC 0004, RFC 0008, and RFC 0009.
