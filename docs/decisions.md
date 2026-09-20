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

Status: Accepted

Treat Execution Provider, runtime/isolation backend, and Evidence Depth as separate architectural dimensions.

An Execution Provider provisions compute. A Provider Adapter integrates infrastructure such as GitHub Actions, Cloudflare, Namespace, RunDiff Fleet, or customer-hosted compute. The runtime describes how customer code executes after placement, for example Docker/OCI, VM, or Firecracker. Evidence Depth describes what RunDiff is allowed and able to observe: Standard, Performance, or Deep.

Commercial review volume is independent of Evidence Depth. Preview uses customer GitHub Actions compute where practical; Review 250, Review 500, Review 1000, and Enterprise describe managed compute quantity rather than evidence quality.

See RFC 0004.

## ADR 0007 - Automatic placement and paired performance execution

Status: Accepted

Use a Workload Profiler plus a deterministic Placement Engine to choose an Execution Provider from workload requirements, requested Evidence Depth, provider capability, policy, measured stability, and expected cost.

Start with explicit auditable rules, collect empirical placement outcomes, and introduce predictive placement only after sufficient evidence exists.

For performance comparison, prefer baseline and candidate execution on the same execution lease and use calibration/interleaving where appropriate. Performance claims are confidence-gated by measured environment noise rather than assuming cloud hardware is absolutely deterministic.

The Go executor is an execution supervisor. It may run as a host daemon, container, or other deployment form; Docker is a workload runtime, not the executor's permanent architectural boundary. Firecracker is a controlled-fleet isolation option, not a determinism guarantee.

See RFC 0004.
