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

RunDiff CI follows a cost-aware fail-fast policy:

1. Cancel stale work. Every PR workflow must use a concurrency group keyed by PR/ref with `cancel-in-progress: true`.
2. Run cheap deterministic checks before expensive integration proofs.
3. Do not start expensive downstream jobs until their prerequisite gate is green.
4. Give every non-trivial job a bounded `timeout-minutes`; a stuck runner must not burn minutes indefinitely.
5. Avoid duplicate execution. Reuse outputs/artifacts when practical instead of rerunning equivalent work.
6. Scope specialized workflows with `paths` so unrelated documentation or UI-only changes do not trigger infrastructure proofs.
7. Keep cleanup steps under `if: always()`, but do not use `continue-on-error` for product correctness.
8. Never treat queued/in-progress RunDiff checks as success.
9. `INFRA_FAILURE` may be rerun.
10. High/critical behavioral regressions block merge.
11. Never accept a baseline without explicit human approval.
12. Stop on `MANUAL_REVIEW_REQUIRED`.

The intended order is:

```text
cheap quality gate
  -> unit/application tests
  -> focused dogfood / subject proofs
  -> exact A/B behavioral comparison
  -> expensive topology / production proofs
```

A newer commit supersedes an older PR run. We optimize for feedback on the newest head, not for completing obsolete work.
