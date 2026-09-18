# Architectural decisions

## ADR 0001 - Rails monolith first

Status: Accepted

Build the initial product in a Rails 8.1 monolith. Keep portable comparison/protocol code free of Rails dependencies when practical.

## ADR 0002 - Execution is the core abstraction

Status: Accepted

Use `Execution` rather than `TestResult`, `PlaywrightSession`, or `BrowserSession` as the universal runtime record. Drivers and frameworks are producers/adapters.

## ADR 0003 - Playwright is a driver, not the platform

Status: Accepted

Use Playwright as the preferred first-party web driver, but never require it for adoption. For Playwright runs, prefer Playwright Trace as the first native diagnostic artifact. Add rrweb-style recording only where continuous or driver-independent replay is needed.

## ADR 0004 - OpenTelemetry and W3C context

Status: Accepted

Use OpenTelemetry semantics and W3C Trace Context for distributed causality. Keep `rundiff.execution.id` as execution-level correlation context in addition to trace/span IDs. Never use it as a metric dimension.

## ADR 0005 - Separate human and agent contracts

Status: Accepted

GitHub comments and dashboards are presentation layers. Agents receive stable machine contracts through Check state, versioned JSON, reason codes, source locations, recommended actions, and later API/MCP.
