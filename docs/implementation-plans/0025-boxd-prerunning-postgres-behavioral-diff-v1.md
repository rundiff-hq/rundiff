# Implementation Plan 0025: Pre-running PostgreSQL Behavioral Diff Benchmark v1

Status: in progress

Tracking issue: #232

## Goal

Measure the real Node/PostgreSQL Behavioral Diff fixture on two Boxd execution
paths that differ only in PostgreSQL lifecycle.

The product fixture and result semantics stay identical.

## Fixture

~~~text
repository: rundiff-hq/example-node-express-postgres
baseline:   e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb
candidate:  a1663f54380e3a117989ebc6f1ab8f525f6bed4e

expected:
  decision=regression
  merge_recommendation=block
  finding=NEW_RUNTIME_ERROR
~~~

Both revisions execute the same PostgreSQL query. The intentional regression is
HTTP 200 -> HTTP 500 in the candidate.

## Golden environments

Two isolated golden parents are prepared in the same live workflow.

Both contain:

- the exact fixture repository;
- npm dependencies;
- the pinned RunDiff Node capture sensor;
- the PostgreSQL 16 Alpine image.

The current-path golden stops there.

The inherited-path golden additionally has:

- one already-running PostgreSQL container;
- a healthy `rundiff_bridge` database;
- a completed `CHECKPOINT`.

Golden construction is deliberately excluded from the primary steady-state
sample timer. BOXD3 already measures cold setup separately.

## Compared paths

### Current

~~~text
prepared golden
      |
 parallel fork
   /       \
baseline candidate
   |         |
docker run PostgreSQL
wait ready
start Node
capture
~~~

### Inherited

~~~text
prepared golden
PostgreSQL already running
      |
 parallel fork
   /       \
baseline candidate
   |         |
verify inherited PostgreSQL
same parent StartedAt
start Node
capture
~~~

No `docker run`, restart, or database recreation is allowed before an
inherited-mode capture.

## Sampling

Run five paired samples in alternating order:

~~~text
sample 1  current -> inherited
sample 2  inherited -> current
sample 3  current -> inherited
sample 4  inherited -> current
sample 5  current -> inherited
~~~

This reduces simple provider/network/warmth ordering bias.

Every sample must independently produce valid Capture v1 for baseline and
candidate, then pass through the existing `comparison.Pair` and Result v1
validation.

## Measurements

Per sample:

- pair fork ready;
- inherited PostgreSQL ready verification, when applicable;
- baseline capture;
- candidate capture;
- comparison;
- pair cleanup;
- total execution from fork start through cleanup.

The machine-readable report records all raw samples plus count, median, p95,
minimum and maximum total time for both modes.

## Correctness

Inherited mode must prove the PostgreSQL container in each child has the exact
same Docker `StartedAt` value as its parent golden before capture.

The fixture does not write application state, so repeated child forks from the
same parent remain deterministic. BOXD4.4 separately proved write divergence,
CHECKPOINT health and restart durability.

## Claim discipline

This benchmark may support a statement about this exact fixture and these
observed Boxd executions.

It must not be generalized to:

- all PostgreSQL workloads;
- external/replicated PostgreSQL;
- arbitrary customer schemas;
- all provider regions or load conditions;
- production placement without the larger provider benchmark.

One timing is not a decision signal. The comparison uses five alternating
samples.

## Evidence

The live workflow writes:

~~~text
apps/executor-go/tmp/rundiff/boxd-prerunning-postgres-benchmark.json
~~~

and uploads it as a 14-day GitHub Actions artifact.

## Acceptance

- five current samples;
- five inherited samples;
- alternating order;
- same exact fixture SHAs;
- valid Capture v1 and Result v1 on every sample;
- same blocking NEW_RUNTIME_ERROR on every sample;
- inherited child StartedAt matches parent;
- no inherited child PostgreSQL recreation before capture;
- raw machine-readable JSON artifact;
- normal CI remains credential-free;
- final provider proof workflow is manual-only;
- no Request v1 / Result v1 changes.
