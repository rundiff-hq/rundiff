# Demo 0001: Behavioral Diff

**The tests passed. RunDiff found what got worse.**

Scenario:

```text
Sign up -> Create project -> Send welcome notification -> Dashboard appears
```

The final product will run the exact same scenario against `main` and a PR. Both may pass while runtime behavior differs.

## Current dogfood implementation

For the first executable slice, RunDiff runs two local-only Rails HTTP executions through its own middleware stack:

```bash
bin/rails db:prepare
bin/rails plywo:dogfood
```

Both executions return success. The candidate intentionally performs more work:

- more SQL queries
- more background-job enqueues
- a duplicate email side effect
- longer request duration

`Plywo::Rails::EvidenceCollector` subscribes to Rails instrumentation while `X-Plywo-Execution-Id` is active. The resulting measurements are passed to the portable `Plywo::BehavioralDiff` engine.

This is deliberately not yet a fake PR checkout. The next slice replaces the demo subject switch with two real Git subjects/worktrees while keeping the evidence and result contracts unchanged.

GitHub headline:

```text
RunDiff / Behavioral Diff
Tests passed on both versions, but behavior changed.
```

Do now: runtime capture, correlation, portable diff, normalized result contract, GitHub report contract.

Do not do yet: generic scenario DSL, rrweb recorder, mobile adapters, Temporal integration, load runner, production replay, TMS UI, or microservices.
