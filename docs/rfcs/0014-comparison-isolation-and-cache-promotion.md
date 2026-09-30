# RFC 0014: Comparison isolation and cache promotion

## Status

Accepted direction. Implementation is incremental.

Captured: 2026-09-30.

## Context

RunDiff compares baseline and candidate behavior. That makes execution-state contamination a correctness problem, not only a performance problem.

Fast compute providers, snapshots, forks, cache volumes, and reusable environments are useful implementation tools, but RunDiff must not make provider-specific VM concepts part of its product semantics.

The durable invariant is:

> Baseline and candidate may share immutable ancestors, but they must not accidentally share mutable execution state.

## Decision summary

1. Baseline and candidate executions must start from equivalent logical inputs for the evidence depth being claimed.
2. A common immutable snapshot, image, dependency layer, or cache parent may be shared.
3. Mutable descendants must be isolated per comparison side.
4. Cache publication is separate from comparison execution.
5. Untrusted candidate execution does not update a trusted shared cache by default.
6. Provider fallback must preserve comparability and be recorded explicitly.
7. If RunDiff cannot establish the required isolation/comparability invariant, the result is INFRA_FAILURE, not a behavioral verdict.

## Isolation invariant

Preferred shape:

~~~text
immutable environment/cache parent
             |
       +-----+-----+
       |           |
       v           v
 baseline       candidate
 writable       writable
 isolated       isolated
 state          state
       |           |
       +-----+-----+
             |
       compare evidence
~~~

The immutable parent may include:

- source-independent toolchain layers;
- dependency caches keyed by lockfiles/toolchain;
- prebuilt images;
- database snapshots where the comparison contract permits them;
- provider snapshots/forks.

The descendants must isolate mutations to:

- filesystem/worktree;
- database state;
- process state;
- temporary files;
- generated artifacts;
- mutable caches;
- service data;
- ports/network namespaces where relevant.

## Cache promotion

A comparison execution may produce a cache candidate, but comparison and publication are different operations.

A cache candidate may be promoted only after policy evaluates at least:

- producing execution outcome;
- infrastructure health;
- provenance;
- source trust;
- cache key compatibility;
- toolchain/runtime identity.

For pull-request or otherwise untrusted candidate code, the default is no promotion into a trusted shared cache.

A provider may implement copy-on-write, protected branches, snapshots, or another mechanism. RunDiff owns the trust/promotion decision, not the provider-specific primitive.

## Fallback order

When the preferred execution strategy is unavailable, RunDiff may degrade through explicit alternatives.

### 1. Parallel isolated descendants

Use two isolated descendants from the same logical parent when the provider supports cheap snapshots/forks or equivalent isolation.

### 2. Sequential paired execution with reset

Run baseline and candidate on the same lease/substrate, restoring or recreating the required mutable state between sides.

This is often preferable for Performance evidence because host variance is reduced.

### 3. Fresh equivalent workers

Use separate fresh workers with equivalent provider, region, shape, runtime, and environment fingerprints.

For Performance evidence, this may reduce confidence and must be reflected in the evidence/confidence model.

### 4. Fail closed on comparability

If the required reset, isolation, or equivalence cannot be proven, return INFRA_FAILURE.

RunDiff must never silently convert contaminated or materially incomparable executions into ALLOW or BLOCK.

## Evidence

Portable execution evidence should preserve enough information to explain how comparison integrity was established.

Candidate fields/concepts:

~~~text
isolation_strategy
environment_parent_id
environment_fingerprint
cache_parent_id
cache_write_scope
cache_promotion_decision
provider_fallback_reason
comparison_confidence
~~~

These names are illustrative until they enter a versioned protocol.

## Interaction with existing strategy

RFC 0004 remains authoritative for Execution Plan, placement, paired execution, evidence depth, and provider fallback.

This RFC adds a stricter invariant:

> Provider fallback is valid only if it preserves the comparison guarantees required by the requested evidence depth.

RFC 0013 remains a BoxD-specific compute-provider design. BoxD forks are one implementation of the isolation model above, not the canonical model itself.

## Non-goals

This RFC does not require:

- Namespace;
- BoxD;
- a RunDiff-owned VM fleet;
- a general cache service;
- always-parallel baseline/candidate execution;
- cache promotion after every successful run.

## External signals

- Namespace exposes cache lineage, protected-branch cache updates, ephemeral compute, and remote execution: https://namespace.so/changelog
- BoxD exposes fast forks/snapshots and isolated machines: https://docs.boxd.sh/llms-full.txt

The product decision in this RFC is RunDiff's own stronger correctness rule, not a claim that either provider implements these exact semantics.
