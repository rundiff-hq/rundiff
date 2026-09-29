# Implementation Plan 0020: Boxd Provider Benchmark v1

Status: complete - first comparative benchmark recorded

Tracking issue: #219

## Goal

Measure Boxd against the current GitHub-hosted managed Go executor path without mixing provider queue latency into executor runtime.

This benchmark answers:

~~~text
For the same known RunDiff behavioral regression,
how much wall-clock time does the current hosted managed executor path take
versus the current Boxd forked-subject path?
~~~

It does not yet answer:

~~~text
Which provider has lower queue latency?
Which provider has lower control-plane dispatch latency?
Which provider is cheaper at production scale?
~~~

Those require separate evidence.

## Fixture

~~~text
repository: rundiff-hq/example-node-express-postgres
baseline:   e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb
candidate:  a1663f54380e3a117989ebc6f1ab8f525f6bed4e
expected:   BLOCK / NEW_RUNTIME_ERROR
~~~

## Hosted path

The hosted comparator runs the production managed Go engine through:

~~~text
rundiff-executor run-local
~~~

on one GitHub-hosted `ubuntu-24.04` runner.

It includes:

~~~text
Prepare
Clone
Bootstrap
SubjectPrepare
Start
Ready
Scenario
Collect
Stop
Teardown
~~~

The normal RunDiff dependency cache root is reused after the first sample.

The benchmark excludes GitHub queue time, control-plane dispatch, claim and heartbeat network latency, and GitHub Check publication.

## Boxd path

The Boxd comparator uses the product-proven SDK provider path from VS19:

~~~text
create isolated golden VM
prepare fixture + dependencies + sensor + PostgreSQL image
fork baseline + candidate
run independent PostgreSQL + Node subjects
capture through the existing Node sensor
compare through comparison.Pair
validate Result v1
cleanup children and golden VM
~~~

This v1 benchmark intentionally measures the currently proven Boxd path, including golden creation/preparation for every sample. A persistent reusable golden parent is a separate optimization and must not be silently assumed in the first comparison.

## Sampling

Run at least five pairs on one GitHub-hosted benchmark job.

Order alternates:

~~~text
pair 1: hosted -> boxd
pair 2: boxd  -> hosted
pair 3: hosted -> boxd
...
~~~

This reduces simple runner-warmth/order bias.

Both paths must produce the same product outcome in every sample:

~~~text
decision=regression
merge_recommendation=block
finding=NEW_RUNTIME_ERROR
~~~

## Evidence

Primary cross-provider metric:

~~~text
wall_ms
~~~

measured around one complete comparator invocation after benchmark executables have already been built.

Hosted samples retain:

- Request v1;
- Result v1;
- Resource Journal;
- phase metrics JSONL;
- stdout/stderr.

Boxd samples retain:

- live test log;
- golden create timing;
- golden preparation timing;
- pair fork timing;
- baseline/candidate capture timing;
- execution timing;
- pair/golden cleanup timing.

The report contains count, median, p95, min and max for both providers plus paired order and per-pair ratio.

## Claim discipline

The v1 result may support a statement about the measured current implementations on this fixture.

It must not be presented as:

- universal Boxd performance;
- GitHub queue performance;
- a production cost result;
- a persistent-golden result;
- evidence for every runtime or customer workload.

A result where Boxd is slower is still useful: it identifies which preparation phases must be removed or amortized before provider promotion.

## Acceptance

1. five or more paired alternating samples;
2. same valid blocking Result v1 semantics on both paths;
3. machine-readable JSON report;
4. raw evidence retained for 14 days;
5. summary recorded here;
6. normal CI remains green;
7. benchmark workflow returns to manual-only before merge.


## Live result - 2026-09-29

GitHub Actions run `36587660042` completed five alternating pairs successfully.
Every hosted and Boxd sample produced the same product result:

~~~text
decision=regression
merge_recommendation=block
finding=NEW_RUNTIME_ERROR
~~~

Primary wall-clock result:

| Path | n | Median | p95 | Min | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| GitHub-hosted managed executor | 5 | 2,417 ms | 2,965 ms | 2,412 ms | 2,965 ms |
| Current Boxd proof path | 5 | 39,738 ms | 48,207 ms | 38,985 ms | 48,207 ms |

For this exact implementation and fixture, the current Boxd proof path had a
median wall time about **16.44x** the hosted managed executor
(`39,738 / 2,417`). The median absolute difference was **37,321 ms**.

This is not evidence that the underlying Boxd fork primitive is intrinsically
16x slower. The two measured implementations currently perform very different
amounts of amortized work.

### Boxd phase evidence

Across the five Boxd samples:

| Phase | Median | p95 |
| --- | ---: | ---: |
| Create isolated golden | 2,054 ms | 2,203 ms |
| Prepare golden | 11,522 ms | 21,709 ms |
| Fork pair ready | 4,473 ms | 4,774 ms |
| Baseline capture | 7,817 ms | 10,226 ms |
| Candidate capture | 7,765 ms | 8,295 ms |
| Pair cleanup | 2,835 ms | 2,843 ms |
| Golden cleanup | 1,405 ms | 1,472 ms |

The current proof recreates and prepares the golden VM on every sample.
Golden preparation includes repository clone, `npm ci`, sensor acquisition,
and PostgreSQL image preparation. Each child capture then starts its own
PostgreSQL container and Node process.

The SDK bridge is also process-per-operation, and `compute.ForkPair` performs
the two forks sequentially.

### Hosted phase evidence

Hosted median phase timings from the production managed engine were:

~~~text
clone                       512 ms
bootstrap base              657 ms
bootstrap candidate         661 ms
ready base                  172 ms
ready candidate             172 ms
scenario                    171 ms
teardown                     55 ms
~~~

The hosted path reused the RunDiff dependency cache after the first sample and
used the already-running PostgreSQL service supplied by the benchmark job.

### Interpretation

The benchmark rejects promoting the **current** Boxd proof path as a latency
optimization.

It also identifies the next experiment precisely. Before another provider
comparison, Boxd should remove or amortize work that the provider architecture
is intended to avoid:

1. reuse a persistent prepared golden machine across executions;
2. replace process-per-operation SDK auth/session setup with a long-lived
   provider session;
3. fork baseline and candidate concurrently;
4. prove whether a running PostgreSQL service can be safely inherited through
   a fork while preserving baseline/candidate write isolation;
5. avoid restarting heavyweight mutable infrastructure in each child when the
   fork primitive can safely carry that state.

Only after those changes should the same five-pair benchmark be rerun.

The raw artifact from run `36587660042` contains all five Result v1 payloads,
hosted phase metrics, Boxd live logs, per-pair order, and the machine-readable
report.
