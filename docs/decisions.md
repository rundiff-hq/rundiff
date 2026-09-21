# Architectural decisions

## ADR 0001 - Rails monolith first

Status: Superseded for the hosted control-plane implementation by ADR 0016. Retained as implementation history.

The initial product was built in a Rails 8.1 monolith to prove the behavioral model, GitHub integration, execution lifecycle, and production contracts quickly. Portable comparison/protocol code was intentionally kept outside Rails-specific boundaries.

The Rails implementation remains a valid reference and future alternate control-plane implementation; Rails is no longer the Control Plane architectural contract.

## ADR 0002 - Execution is the core abstraction

Status: Accepted

Use Execution rather than TestResult, PlaywrightSession, or BrowserSession as the universal runtime record. Drivers and frameworks are producers/adapters.

## ADR 0003 - Playwright is a driver, not the platform

Status: Accepted

Use Playwright as the preferred first-party web driver, but never require it for adoption. For Playwright runs, prefer Playwright Trace as the first native diagnostic artifact. Add rrweb-style recording only where continuous or driver-independent replay is needed.

## ADR 0004 - OpenTelemetry and W3C context

Status: Accepted

Use OpenTelemetry semantics and W3C Trace Context for distributed causality. Keep rundiff.execution.id as execution-level correlation context in addition to trace/span IDs. Never use it as a metric dimension.

## ADR 0005 - Separate human and agent contracts

Status: Accepted

GitHub comments and dashboards are presentation layers. Agents receive stable machine contracts through Check state, versioned JSON, reason codes, source locations, recommended actions, and later API/MCP.

## ADR 0006 - Separate execution provider, runtime, and evidence depth

Status: Superseded by ADR 0008

The original decision correctly separated infrastructure from runtime and Evidence Depth, but the flat Execution Provider concept was still too broad. RFC 0004 now decomposes execution into an Execution Plan with distinct orchestration, compute, runner, runtime, resource, parallelism, evidence, and policy roles.

## ADR 0007 - Automatic placement and paired performance execution

Status: Accepted

Use a Workload Profiler plus a deterministic Placement Engine to choose an Execution Plan from workload requirements, requested Evidence Depth, infrastructure capabilities, policy, measured stability, parallelism requirements, and expected cost.

Start with explicit auditable rules, collect empirical placement outcomes, and introduce predictive placement only after sufficient evidence exists.

For performance comparison, prefer baseline and candidate execution on the same execution lease and use calibration/interleaving where appropriate. Performance claims are confidence-gated by measured environment noise rather than assuming cloud hardware is absolutely deterministic.

The Go executor is an execution supervisor. It may run as a host daemon, container, external-CI agent step, or another deployment form. Docker is a workload runtime, not the executor's permanent architectural boundary. Firecracker is a controlled-fleet isolation option, not a determinism guarantee.

See RFC 0004.

## ADR 0008 - Execution Plan is the composition boundary

Status: Accepted

Do not model execution infrastructure as one flat provider choice.

The control plane produces an Execution Plan that may independently describe:

- execution orchestrator;
- compute provider;
- optional runner backend and provenance;
- runtime/isolation backend;
- resources and region;
- parallelism;
- Evidence Depth;
- comparison strategy;
- placement and fallback policy.

Vendor identity is not an architectural role. One vendor may fill several roles, and one plan may combine several vendors.

The Placement Engine evaluates complete plans rather than choosing a single provider string.

Review volume is a commercial dimension separate from Evidence Depth. Wall-clock minutes are not a durable billing unit because machine size and parallelism change aggregate compute. Review Credits are the working normalized managed-compute abstraction, while Behavioral Review is the preferred customer-facing usage concept.

See RFC 0004.

## ADR 0009 - Repository-owned RunDiff configuration

Status: Accepted

Use /rundiff.yml at the repository root as the canonical configuration location across Rails, Go, Java, Python, Node, Rust, and future stacks.

Git is the source of truth for execution intent. The RunDiff control panel may provide a visual editor and keep temporary drafts, but it must not maintain a hidden competing workload policy that silently overrides the committed repository configuration.

RunDiff configuration is framework-neutral and must not live under .github/, Rails config/, or another framework-specific directory.

The configured execution unit is a Review Workload, not necessarily the repository's entire CI suite. Workloads may be explicit, dynamic, or full and may contain tests, scenarios, commands, browser flows, benchmarks, or future agent-generated flows.

See RFC 0007.

## ADR 0010 - Source code stays in the execution boundary

Status: Accepted

Do workload discovery and customer-code execution inside a disposable execution environment or customer-controlled CI environment.

The Rails control plane does not need to persist a private repository checkout merely to enumerate or select tests.

The control plane may receive and retain only the derived metadata, evidence, artifacts, and product state required by policy. Test paths, names, tags, traces, SQL fingerprints, and similar derived data are still customer data and must be handled accordingly.

Repository access for managed execution remains short-lived, repository-scoped, and read-only where possible.

See RFC 0007 and docs/executor.md.

## ADR 0011 - Configuration writes happen through user-confirmed GitHub UI

Status: Accepted

Do not add permanent repository Contents: write permission to the main RunDiff GitHub App merely to create or update rundiff.yml.

For the standard hosted flow, RunDiff generates the configuration in the control panel and hands the user into GitHub's browser UI. The authenticated GitHub user reviews the file and explicitly creates the branch/commit/pull request using their own permissions.

The happy path must not require manual copy/paste. Undocumented GitHub URL-prefill parameters may be used only behind an integration adapter and must not become a durable protocol assumption.

RunDiff may still require write permissions for non-content GitHub product surfaces such as Checks or PR comments.

See RFC 0007.

## ADR 0012 - Ownership-aware routing is separate from causality

Status: Accepted

Resolve ownership for findings and use it to route Behavioral Reviews to relevant people and systems.

CODEOWNERS is the preferred first ownership source. Scenario ownership and future service catalogs may add additional ownership context.

Ownership is not root-cause attribution. RunDiff may state that a team owns an affected path or scenario; it must not claim that the team caused the regression solely from ownership.

Routing policy is separate from Behavioral Diff. GitHub is the primary review surface, while Slack, Teams, Discord, Telegram, email, generic webhooks, issue/incident systems, and future agents are optional policy-controlled delivery targets.

Infrastructure failures should route to CI/RunDiff operational ownership rather than application CODEOWNERS by default.

See RFC 0008.


## ADR 0013 - Managed executor is Go; sensors stay out of process

Status: Accepted

Implement the managed RunDiff Executor in Go.

The executor is an execution supervisor for foreign processes, containers, cgroups, namespaces, cancellation, lifecycle, and evidence transport. It is not primarily a CPU-bound data plane.

Keep sensors and low-level evidence collectors behind language-neutral process/protocol boundaries. Prefer Go first. Introduce Rust only when a measured low-level requirement justifies it.

Do not use cgo in the managed executor. If a capability needs native code, prefer an out-of-process sensor or another explicit boundary.

This is an implementation decision, not part of the public RunDiff protocol or customer contract.

See RFC 0006 and RFC 0009.


## ADR 0014 - GitHub identity and repository installation are separate boundaries

Status: Accepted

Treat GitHub user authentication and GitHub App installation as separate product/security concerns.

GitHub authentication answers:

> Who is this RunDiff user?

GitHub App installation answers:

> Which repositories may RunDiff observe and review?

The ordinary login flow should request only the identity/profile permissions needed for RunDiff account access. It should not request broad repository write scope merely so RunDiff can create or update /rundiff.yml.

Repository access comes from the GitHub App installation and remains repository-scoped according to installation selection and App permissions.

Configuration changes use the user-confirmed GitHub browser handoff from ADR 0011 / RFC 0007 rather than a broad OAuth repository-write token stored by RunDiff.

This separation keeps authentication lightweight, repository authorization explicit, and repository-content writes outside the permanent RunDiff credential set.

See RFC 0007 and docs/github-app-setup.md.


## ADR 0015 - Behavioral analysis uses explicit Rule, Finding, Diagnosis, Relation, and Decision concepts

Status: Accepted

Keep `RunDiff::Executor::Request` and `RunDiff::Executor::Result` as the portable executor transport boundary.

Do not use one flat reason-code taxonomy as the long-term behavioral analysis model.

RunDiff analysis separates:

- Evidence - what was observed;
- Rule - reusable analysis semantics;
- Finding - one concrete evidence-backed behavioral change;
- Diagnosis - an interpretation/hypothesis about one or more findings;
- Relation - a typed edge such as depends_on, contributes_to, correlates_with, or causes;
- Decision - ALLOW/REVIEW/BLOCK policy outcome;
- Execution Failure - infrastructure/workload failure to produce the intended evidence contract.

Findings are classified with orthogonal facets such as domain, quality dimension, resource, scope, change kind, and causal role rather than one rigid category tree.

Use OpenTelemetry Semantic Conventions as preferred evidence vocabulary where applicable, ISO/IEC 25010:2023 as a reference for high-level quality dimensions, SARIF as prior art/export shape for Rule/Finding semantics, and IEC 62740 as guidance for future investigation/root-cause semantics. These references do not make RunDiff conformant to those standards.

Schema v1 remains compatible: legacy `reason_code` stays valid while stable dotted `rule_id` values are introduced incrementally.

See RFC 0010.


## ADR 0016 - Control Plane is implementation-independent; Cloudflare-native is production v1

Status: Accepted

Define **RunDiff Control Plane** as a product/domain authority, not as a Rails application, Worker, database, queue, or vendor-specific runtime.

The Control Plane owns durable product semantics such as:

- Behavioral Review identity and lifecycle;
- exact repository/base/candidate identity;
- GitHub delivery deduplication;
- execution creation and current-attempt authority;
- stale/supersede checks;
- finalization fencing;
- policy/decision authority;
- GitHub publication state;
- user/project/install metadata;
- placement/execution-plan state;
- retained evidence metadata.

Implementations satisfy those responsibilities through explicit ports/adapters. Infrastructure-specific primitives must not become the RunDiff domain model.

The selected **first production proof implementation** is Cloudflare-native:

~~~text
React SPA
  + Hono Worker API
  + D1 durable relational state
  + Cloudflare Workflows for durable execution lifecycle
  + R2 for large retained artifacts/evidence
  + Workers secrets/configuration

Execution:
  GitHub Actions first
  Cloudflare Containers later
~~~

Cloudflare Workflows replace Solid Queue/lease-reaper mechanics only inside this implementation. They do not redefine the portable execution lifecycle or Executor Request/Result contracts.

D1 is the v1 state adapter. It is not the permanent RunDiff database contract.

R2 is the v1 artifact adapter. It is not the permanent artifact-storage contract.

Durable Objects and Cloudflare Queues are intentionally deferred until a concrete need appears:

- Durable Objects for serialized project/repository coordination when D1 + Workflow lifecycle is insufficient;
- Queues for fan-out, notification/event delivery, or high-volume asynchronous streams.

The current Rails implementation remains in the repository as:

- a proven reference implementation;
- a behavioral/runtime dogfood target;
- a fallback path for a future Rails/PostgreSQL/VPS control plane;
- a source of tested lifecycle semantics that the Cloudflare implementation must preserve.

A future implementation may use Rails/PostgreSQL/Temporal, Go, another database, another workflow engine, or another cloud without changing RunDiff's public/domain contracts.

See RFC 0011.


## ADR 0017 - Dependency cache belongs to the executor infrastructure boundary

Status: Accepted

Moving the managed executor from Ruby to Go does not remove or weaken package-manager caching. The Go executor supervises dependency installation; it does not replace Bundler, npm, uv/pip, Go modules, Gradle, Maven, or future package managers.

Treat dependency caching as runtime-neutral executor infrastructure:

~~~text
Go Executor
  -> detect runtime/package manager
  -> derive content-addressed dependency identity
  -> restore local/shared cache
  -> run the native package manager deterministically
  -> retain reusable package artifacts
  -> run the runtime sensor
~~~

Cache identity must include enough execution context to prevent unsafe reuse, including a trust namespace (repository/tenant boundary), runtime line, package-manager version, platform/architecture, and the committed dependency lock digest. A cache hit must never relax frozen/locked installation semantics or allow the package manager to mutate customer lockfiles.

Baseline and candidate may share the same cache entry when their dependency identity is identical. If the lockfile changes, they receive distinct identities. Future cache implementations may safely reuse lower-level content-addressed package blobs across identities, but a prepared dependency environment must not be shared across incompatible identities.

Do not blindly cache arbitrary customer workspaces. Prefer package-manager artifact/download stores and reproducible prepared dependency directories with explicit identity and validation.

The cache has two placement layers:

- local executor cache for fast reuse on a persistent managed/BYOC host;
- optional external-CI/shared cache adapter for ephemeral runners such as GitHub Actions.

Sensors do not own dependency caches. Rails, Node, Python, Go, Java, and future sensors consume already prepared subjects.

Performance reporting must distinguish cold and warm dependency bootstrap. The primary product metric is warm RunDiff overhead on a PR with reusable dependencies, not a synthetic Go-versus-Ruby language speedup.

Observed production evidence motivating this decision:

~~~text
VS6 Rails/Bundler bootstrap
  cold baseline:  32.895 s
  warm candidate:  0.316 s
~~~

That ~104x phase difference is a cold-versus-warm cache observation, not a Go-versus-Ruby speedup.

See docs/executor.md and implementation plan 0014.
