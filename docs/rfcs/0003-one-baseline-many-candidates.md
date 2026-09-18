# RFC 0003: One baseline, many candidates

## Status

Accepted for the comparison contract. Playwright/runner orchestration follows in a later slice.

## Problem

An agent can create several independent implementations of the same task in local clones, forks, or git worktrees. Comparing each implementation in isolation loses the ability to rank alternatives under identical behavioral evidence.

## Contract

A comparison has exactly one baseline and one or more candidates.

```text
baseline
  ├── candidate-a
  ├── candidate-b
  ├── candidate-c
  └── ... candidate-n
```

Every candidate is executed against the same scenario set and compared independently with the baseline. The versioned comparison result stores all candidate results plus a deterministic ranking.

The runner is not required to be Playwright. Playwright CLI is the first web-oriented driver, but the comparison contract also supports API, mobile, load, and agent-driven runners.

## GitHub projection

A GitHub PR normally has one candidate: the PR head against its base ref. GitHub presentation therefore renders one candidate deeply.

CLI and RunDiff UI may render many candidates as a matrix/ranking. This keeps GitHub feedback concise without constraining the core model to one candidate.

## Local agent workflow

A future CLI can accept one baseline subject plus N candidate subjects, including worktree or directory paths:

```text
rundiff compare --baseline ./main \
  --candidate ./attempt-1 \
  --candidate ./attempt-2 \
  --candidate ./attempt-3
```

The CLI should execute the same scenario corpus across all subjects, persist execution evidence, rank candidates, and optionally publish the comparison to RunDiff UI.
