# Architectural decisions

## ADR 0001 - Rails monolith first

Status: Accepted

Build the initial product in a Rails 8.1 monolith. Keep portable comparison/protocol code free of Rails dependencies when practical.

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
