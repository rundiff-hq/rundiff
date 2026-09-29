# Implementation Plan 0025: Pre-running PostgreSQL Product Path v1

Status: complete - pre-running PostgreSQL product path benchmarked live

Tracking issue: #232

## Goal

Measure the real RunDiff Node/PostgreSQL Behavioral Diff path when PostgreSQL is already running in the Boxd golden before fork.

BOXD4.4 proved the underlying database primitive:

~~~text
running PostgreSQL parent
        |
    parallel fork
     /       \
 baseline   candidate
    |           |
 independent SQL/WAL state
    |           |
 CHECKPOINT  CHECKPOINT
    |           |
 restart     restart
    |           |
 durable divergent state
~~~

This slice asks the product question: does that primitive materially reduce fork-to-result latency for the known fixture while preserving the exact same Capture v1 and Result v1 semantics?

## Fixture

~~~text
repository: rundiff-hq/example-node-express-postgres
baseline:   e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb
candidate:  a1663f54380e3a117989ebc6f1ab8f525f6bed4e
expected:   regression -> block -> NEW_RUNTIME_ERROR
~~~

## Compared steady-state paths

### Current

~~~text
prepared golden
  repo + npm deps + sensor + PostgreSQL image
            |
       parallel fork
       /           \
 baseline         candidate
 docker run PG    docker run PG
 wait PG          wait PG
 start Node       start Node
 capture          capture
       \           /
        Behavioral Diff
~~~

### Pre-running PostgreSQL

~~~text
prepared golden
  repo + npm deps + sensor
  PostgreSQL already running + healthy
            |
       parallel fork
       /           \
 baseline         candidate
 inherited PG     inherited PG
 start Node       start Node
 capture          capture
       \           /
        Behavioral Diff
~~~

The experimental child capture script must never remove, recreate, or restart PostgreSQL before capture.

## Sampling

Prepare the two golden parents once.

Run five paired samples on one GitHub-hosted proof job and alternate order:

~~~text
sample 1: current -> pre-running
sample 2: pre-running -> current
sample 3: current -> pre-running
sample 4: pre-running -> current
sample 5: current -> pre-running
~~~

Every sample must produce the same product outcome.

## Correctness

For every pre-running sample:

- both children must inherit PostgreSQL with the exact parent container StartedAt;
- Capture v1 identity/status must validate;
- baseline must remain HTTP 200 / passed;
- candidate must remain HTTP 500 / failed;
- existing comparison must produce blocking NEW_RUNTIME_ERROR;
- an isolation marker written to baseline PostgreSQL must be invisible to candidate;
- a candidate marker must be invisible to baseline;
- the golden parent must remain marker-free after all samples.

## Metrics

Record per path/sample:

- pair fork-ready;
- inherited PostgreSQL ready for the experimental path;
- baseline capture;
- candidate capture;
- comparison;
- pair cleanup;
- total fork-to-cleanup.

Primary comparison:

~~~text
median total_ms
median baseline_capture_ms + candidate_capture_ms
~~~

Golden preparation time is recorded separately and excluded from the steady-state comparison.

## Evidence artifact

Write a JSON report containing:

- exact fixture SHAs;
- all paired samples;
- per-phase timings;
- medians;
- current/pre-running latency ratios.

Retain the artifact for 14 days.

## Claim discipline

This experiment is specific to:

- Boxd;
- PostgreSQL 16 Alpine;
- the Node/Express/PostgreSQL fixture;
- one local PostgreSQL service;
- one GitHub-hosted proof job.

A positive result does not automatically enable Boxd placement or establish performance for Rails, larger databases, replicas, external services, or production traffic.

## Acceptance

- five alternating paired samples;
- same valid Capture v1 / Result v1 outcome for both paths;
- inherited PostgreSQL identity verified on every experimental pair;
- DB isolation verified;
- machine-readable benchmark report;
- normal CI green;
- final live workflow manual-only;
- no Request v1 / Result v1 changes.


## Live evidence - 2026-09-29

GitHub Actions Boxd provider proof run `36616948185` completed successfully on
commit `c780f996080356f0045880e629b8ec8486c199c1`.

All existing Boxd provider proofs remained green, including the running
PostgreSQL fork durability proof. Every current-path and pre-running-path sample
also produced the same portable product result:

~~~text
decision=regression
merge_recommendation=block
finding=NEW_RUNTIME_ERROR
~~~

### Paired samples

| Sample | First | Current total | Pre-running total | Current captures | Pre-running captures |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | current | 15,698 ms | 6,226 ms | 13,310 ms | 3,441 ms |
| 2 | pre-running | 14,034 ms | 6,116 ms | 12,851 ms | 3,262 ms |
| 3 | current | 13,661 ms | 5,877 ms | 12,342 ms | 3,049 ms |
| 4 | pre-running | 13,784 ms | 6,139 ms | 12,621 ms | 3,227 ms |
| 5 | current | 14,655 ms | 5,791 ms | 13,483 ms | 2,883 ms |

Median result:

~~~text
current total median       = 14034 ms
pre-running total median   =  6116 ms
current/pre-running ratio  = 2.295x

current capture median     = 12851 ms
pre-running capture median =  3227 ms
current/pre-running ratio  = 3.982x
~~~

On this fixture, moving PostgreSQL startup into the golden reduced median
combined capture time by 9,624 ms and reduced median steady-state
fork-to-result-plus-cleanup time by 7,918 ms.

### Timing semantics

For the pre-running path, `total_ms` contains:

~~~text
parallel pair fork
+ inherited PostgreSQL readiness/identity verification
+ baseline capture
+ candidate capture
+ comparison
+ pair cleanup
~~~

The benchmark also performs additional SQL marker writes and cross-role
isolation queries as test-only correctness checks. Those checks took roughly
4.3-4.8 seconds per sample and are recorded separately as
`isolation_verification_ms`; they are deliberately excluded from product
`total_ms`.

This fixes an earlier intermediate measurement that accidentally included
test-only isolation work in the experimental product latency.

### Golden preparation

One-time preparation observed in the same run:

~~~text
current golden prepare     =  9467 ms
pre-running golden prepare = 13758 ms
extra pre-running prepare  =  4291 ms
~~~

The pre-running golden pays additional one-time service startup. On this small
fixture, the observed median steady-state saving is larger than that one-time
difference, so the extra preparation would be amortized within the first
execution. This is fixture-specific evidence, not a general production cost
claim.

### Machine-readable evidence

Workflow artifact:

~~~text
boxd-prerunning-postgres-product-36616948185-1
artifact id: 11055113830
retention: 14 days
digest:
sha256:6844df129d42388b6f6c5d5fe280f950351ab2a507536e0373e8c9eb77badfb6
~~~

The JSON artifact contains exact fixture SHAs, all paired phase timings,
test-only isolation verification timings and summary medians/ratios.

### Decision

For the known Node/PostgreSQL fixture, **pre-running PostgreSQL should become
the preferred Boxd experimental product path**.

Do not yet enable Boxd as a default placement provider. The next step is to
connect this pre-running service state to the persistent fingerprinted Golden
Environment Manager and rerun the broader Boxd-vs-hosted benchmark with a
reused golden across executions.

The safe scope remains narrow:

- PostgreSQL 16 Alpine;
- local Docker PostgreSQL;
- known Node fixture;
- no replicas;
- no external DB clients during fork;
- no migration in progress;
- no distributed/external storage.
