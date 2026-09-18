# RFC 0006: Adaptive paired timing sampling

Status: Proposed

## Problem

RunDiff currently compares one baseline capture with one candidate capture. This is strong for deterministic evidence such as SQL counts, jobs, emails, HTTP counts, runtime errors, and functional/correlation failures.

A single latency observation is different. Queue scheduling, process startup, runner contention, CPU scheduling, and shared CI infrastructure can move enough to cross a percentage threshold without any code-caused regression.

PR #102 and later RunDiff dogfood runs demonstrated the failure mode: the same logical change can cross a timing threshold once and be stable on the next run while deterministic evidence remains identical.

Always running every subject three or five times would improve timing evidence, but it would also multiply CI cost and feedback latency even when no timing signal is suspicious.

## Decision

Use **adaptive paired sampling**.

Run one baseline/candidate pair first. Additional pairs are collected only when the first pair contains timing-only evidence that would otherwise affect the merge recommendation.

The first implementation targets three total pairs: one initial pair plus two confirmatory pairs.

## Decision flow

```text
capture pair 1
  |
  +-- deterministic blocking finding? --> BLOCK immediately
  |
  +-- no timing threshold crossed? ----> ALLOW
  |
  +-- timing-only threshold crossed? --> provisional REVIEW
                                         |
                                         v
                                  capture pairs 2 + 3
                                         |
                                         v
                                  robust aggregation
                                         |
                         +---------------+---------------+
                         |                               |
                  confirmed signal                insufficient signal
                         |                               |
                       BLOCK                            REVIEW
```

Deterministic findings never wait for timing confirmation.

## Pairing and order

Samples preserve exact baseline/candidate SHAs, scenario contract, executor capabilities, and isolation policy.

Pairs are interleaved with deterministic alternating order:

```text
pair 1: baseline  -> candidate
pair 2: candidate -> baseline
pair 3: baseline  -> candidate
```

Alternating the first side reduces systematic order bias while keeping each pair adjacent in time.

The plan is deterministic rather than randomized so a proof can be reproduced exactly.

## Mutable state

Every capture pair uses fresh sample-scoped mutable state.

Conceptually:

```text
base_s1
candidate_s1
candidate_s2
base_s2
base_s3
candidate_s3
```

Role and sample index are structured fields, not an opaque string contract.

An environment may participate in repeated sampling only if it advertises `state.sample_isolated`.

SQLite and PostgreSQL state isolation/reset are tracked by #137.

Immutable trusted dependency/bootstrap artifacts may be reused across samples. Writable application/database/runtime state may not.

## Aggregation

Timing aggregation is based on paired observations.

For each timing signal, RunDiff records:

- `sample_count`
- baseline median
- candidate median
- median paired delta
- robust percentage delta relative to the baseline median
- median absolute deviation (MAD) of paired deltas
- sample quality

The low-level aggregator does not decide BLOCK/REVIEW. It reports robust evidence; the policy layer decides whether dispersion is good enough for blocking confidence.

The initial math contract is implemented on the preparation branch `feat/paired-timing-samples`.

## Confidence states

The intended user-facing progression is:

```text
single_sample_timing
  -> sampled_timing
  -> insufficient_signal
```

`single_sample_timing` is reportable but review-only.

`sampled_timing` means the configured minimum paired evidence exists and the policy layer considers dispersion acceptable.

`insufficient_signal` means RunDiff observed a timing change but cannot support a precise merge-blocking claim within the configured sample budget.

No timing finding should silently disappear merely because confidence is low.

## Thresholds

The existing absolute + percentage thresholds remain useful as **signal detection thresholds**.

They are not, by themselves, confidence thresholds.

A repeated timing regression should require:

1. enough paired samples;
2. robust median delta crossing the signal's absolute threshold;
3. robust percentage delta crossing the signal's percentage threshold;
4. dispersion acceptable to the policy layer.

The exact dispersion rule should be introduced with evidence and fixtures rather than guessed inside the aggregation primitive.

## CI cost policy

Adaptive sampling follows the repository CI policy:

- cheap/deterministic evidence first;
- no extra samples when the first pair is stable;
- deterministic blockers stop immediately;
- confirmatory samples only for timing-only ambiguity;
- bounded sample count;
- a newer PR head cancels stale sampling work.

This keeps the common path close to current cost while spending extra runtime only where better evidence can change the decision.

## Failure policy

If confirmatory sampling cannot complete because of infrastructure failure:

- do not convert the timing finding into BLOCK;
- keep deterministic findings unchanged;
- report REVIEW / insufficient evidence for the timing component;
- preserve the infrastructure failure separately when it materially prevents the requested proof.

A failed sample must be cleaned before another sample is attempted.

## Result contract

A sampled timing finding should eventually expose evidence similar to:

```json
{
  "reason_code": "DISPATCH_WAIT_REGRESSION",
  "signal": "dispatch_wait_ms",
  "blocking": true,
  "confidence": "sampled_timing",
  "evidence": {
    "mode": "paired_samples",
    "sample_count": 3,
    "baseline_median": 151.0,
    "candidate_median": 158.1,
    "median_delta": 5.6,
    "delta_percent": 3.709,
    "delta_mad": 1.6
  }
}
```

The numbers above illustrate the shape, not a confirmed regression.

GitHub Check/comment output should explain sample count, robust center, dispersion, and confidence rather than showing a single point estimate as if it were exact.

## Rollout

1. Interim policy: single-sample timing findings are REVIEW-only.
2. Land sample-scoped state isolation (#137).
3. Land policy-neutral paired sample plan + aggregation.
4. Add adaptive confirmatory sampling to the local/executor runner.
5. Extend finding/result schema for sampled evidence.
6. Promote repeatable timing findings back to blocking confidence.
7. Keep dogfooding thresholds and dispersion policy with real CI evidence.

## Non-goals

This RFC does not:

- average deterministic counts across samples;
- hide timing findings;
- allow shared writable state between baseline and candidate;
- make production executor timeouts longer;
- require every RunDiff execution to pay a fixed 3x runtime cost.
