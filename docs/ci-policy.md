# CI execution policy

RunDiff treats CI minutes, runner occupancy, and feedback latency as finite resources.

## Invariants

- **Newest head wins.** A newer commit cancels queued or running work for the older PR head.
- **Fail cheap first.** Formatting, static analysis, security scanning, and other deterministic checks run before integration-heavy proofs.
- **Gate expensive work.** Docker builds, production topology proofs, remote executor proofs, and full A/B runtime comparisons should only run after cheaper prerequisites pass.
- **Bound every job.** Jobs that can hang have explicit timeouts.
- **Do not duplicate equivalent work.** Prefer one authoritative execution result and reuse it where practical.
- **Run only relevant proofs.** Specialized workflows use path filters.
- **Cleanup is unconditional.** Resource cleanup runs with `if: always()`; correctness checks do not use `continue-on-error`.
- **Stale results are disposable.** We do not spend minutes finishing a result for a commit that is no longer the PR head.

## Default workflow shape

```text
quality
  |
  v
test + focused runtime proofs
  |
  +--> exact A/B comparison when supported
  |
  v
remote / topology / production proofs
```

## Concurrency

PR-oriented workflows use a group derived from the workflow name and PR number (or ref for non-PR events):

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

This means a push to the same pull request cancels obsolete work and immediately gives runner capacity to the newest head.

## Timeouts

Timeouts are deliberately tighter than GitHub's platform maximum. A timeout is an infrastructure guardrail, not a performance target. If a proof legitimately needs more time, change the bound explicitly with evidence rather than removing it.

## Release builds

Release-image work is deduplicated by the exact release SHA/ref. Re-triggering the same release cancels the older duplicate, while different release SHAs do not cancel each other.

## Future optimization

As RunDiff gains reusable execution artifacts, candidate evidence and immutable image layers should be reused across checks instead of recomputed. The long-term goal is not merely faster CI; it is **one execution, many consumers**.
