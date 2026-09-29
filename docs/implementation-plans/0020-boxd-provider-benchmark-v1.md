# Implementation Plan 0020: Boxd Provider Benchmark v1

Status: in progress

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
