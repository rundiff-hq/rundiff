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
