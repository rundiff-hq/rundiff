# AGENTS.md

## Product invariant

RunDiff answers:

> What did this software change actually change?

Do not reduce RunDiff to a test dashboard, CI wrapper, Playwright plugin, or generic observability backend.

## Rules

1. `RunDiff Execution` is the central abstraction.
2. Playwright, Cypress, Capybara, Maestro, CLI processes, language tests, load tools, and agents are producers/adapters.
3. Keep portable contracts and comparison logic independent of Rails when practical.
4. Rails is the initial product shell, not the permanent boundary for every component.
5. Prefer OpenTelemetry and W3C Trace Context over custom tracing protocols.
6. `rundiff.execution.id` is correlation context, not a metrics dimension.
7. GitHub comments are for humans; stable JSON/API/MCP contracts are for agents.
8. Adoption must not require rewriting an existing test suite.
9. Never silently accept a regression as a new baseline.
10. Distinguish product regression from infrastructure failure.

## Current slice

Behavioral Diff:

- baseline passes;
- candidate passes;
- candidate changes runtime behavior;
- RunDiff explains the regression;
- GitHub gets a concise report;
- agents get stable machine-readable findings.

Keep work aligned with this slice until it is end-to-end.

## Agent CI policy

- Never treat queued/in-progress RunDiff checks as success.
- `INFRA_FAILURE` may be rerun.
- High/critical behavioral regressions block merge.
- Never accept a baseline without explicit human approval.
- Stop on `MANUAL_REVIEW_REQUIRED`.
