# Product thesis

RunDiff shows what a software change actually changed.

A pull request can pass every assertion and still double latency, create N+1 queries, enqueue duplicate jobs, send duplicate notifications, alter webhook payloads, increase memory, or change network behavior.

Traditional testing primarily answers whether assertions passed. Observability primarily explains running systems. RunDiff connects change validation with execution evidence before merge.

```text
Change -> subjects A/B -> scenario -> executions -> evidence -> behavioral diff -> decision
```

## Principles

1. Evidence over assertions.
2. Compare, do not merely observe.
3. Bring your own tests.
4. Scenario identity is independent of the driver.
5. GitHub is a decision surface; RunDiff is the investigation surface.
6. Agent-readable by design.
7. Prefer OTLP and W3C Trace Context over custom protocols.
8. Rails first, extraction-ready.
9. No silent baseline acceptance.
10. Separate product regressions from infrastructure failures.

RunDiff is not a new test framework. Playwright, Capybara, Cypress, Maestro, `cargo test`, arbitrary CLI commands, k6 profiles, and agent-driven flows can all produce a RunDiff Execution.
