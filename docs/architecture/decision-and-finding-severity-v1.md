# Decision and Finding Severity v1

RunDiff separates the merge/deploy decision from the severity of individual findings.

## Decision

A review has one terminal decision:

```text
ALLOW
BLOCK
INFRA_FAILURE
```

These values are intentionally small and unambiguous because they map to automation and merge/deploy gating.

## Finding severity

Individual behavioral differences can carry a severity:

```text
INFO
WARNING
BLOCKING
```

Semantics:

- `INFO` — noteworthy evidence with no action required.
- `WARNING` — suspicious or degraded behavior that should be shown prominently but does not cross a blocking policy threshold.
- `BLOCKING` — a finding that crosses a configured hard policy and contributes to `BLOCK`.

## Composition

Decision is derived from execution health and findings, not encoded directly as a finding severity.

```text
executor/infrastructure failure
  -> INFRA_FAILURE

one or more BLOCKING findings
  -> BLOCK

no BLOCKING findings
  -> ALLOW
     + zero or more INFO/WARNING findings
```

This means the product may display:

```text
ALLOW
ALLOW · 2 warnings
BLOCK · 1 blocking · 2 warnings
INFRA_FAILURE
```

but the API decision remains `ALLOW | BLOCK | INFRA_FAILURE`.

## Why WARNING is not a fourth decision

Making `WARNING` a peer of `ALLOW` and `BLOCK` would make gating ambiguous:

- Is WARNING mergeable?
- Does it require a human?
- Is it a success or failure for GitHub Checks?
- How does WARNING compose with one blocking finding?

Keeping decision and severity orthogonal avoids those ambiguities.

## Product proof strategy

The canonical external multi-runtime acceptance proof stays intentionally simple:

```text
intentional regression
  -> BLOCK

fix same PR
  -> ALLOW
```

A separate follow-up proof should demonstrate a non-blocking regression:

```text
soft threshold exceeded
  -> ALLOW + WARNING
```

Good warning candidates include moderate latency growth, moderate SQL-query growth, increased allocation/CPU cost, or a newly observed network dependency that remains below the configured blocking threshold.
