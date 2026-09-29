# Implementation Plan 0025: Pre-running PostgreSQL Behavioral Diff Benchmark v1

Status: complete - inherited PostgreSQL product path benchmarked live

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


## Live evidence - 2026-09-30

The canonical artifact-producing live run is GitHub Actions run
`36634207997` on commit `cb9eb0a21265ae54e414be6e9ceb548412d66144`.

The workflow passed all existing Boxd regression guards and the new ten-run
product benchmark. The raw JSON artifact was uploaded as:

~~~text
boxd-prerunning-postgres-benchmark-36634207997-1
artifact id: 11063244083
retention: 14 days
sha256:
0e56764a571c123198c581c2309889acfdbd1e051e1f06c7aedbc651684d431d
~~~

Every sample independently produced:

~~~text
Capture v1 baseline   valid
Capture v1 candidate  valid
Result v1             valid
decision              regression
merge recommendation  block
finding               NEW_RUNTIME_ERROR
~~~

### Canonical five-pair sample

| Pair | First | Current total | Inherited total |
| ---: | --- | ---: | ---: |
| 1 | current | 14,870 ms | 5,631 ms |
| 2 | inherited | 13,927 ms | 5,614 ms |
| 3 | current | 13,763 ms | 5,580 ms |
| 4 | inherited | 13,635 ms | 5,759 ms |
| 5 | current | 13,389 ms | 5,903 ms |

Summary:

| Path | Count | Median | p95 | Min | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| post-fork PostgreSQL start | 5 | 13,763 ms | 14,870 ms | 13,389 ms | 14,870 ms |
| inherited running PostgreSQL | 5 | 5,631 ms | 5,903 ms | 5,580 ms | 5,903 ms |

~~~text
median speedup = 2.444x
median saved   = 8.132 s per paired product execution
~~~

The p95 values use nearest-rank semantics for five samples and therefore equal
the maximum observation.

### Phase evidence

Current-path role capture remained dominated by per-child PostgreSQL startup:

~~~text
baseline capture  6,162-6,632 ms
candidate capture 6,074-6,354 ms
~~~

Inherited mode, while still verifying the already-running database before
capture, measured:

~~~text
inherited PostgreSQL ready  1,491-1,589 ms
baseline capture            1,422-1,684 ms
candidate capture           1,452-1,668 ms
~~~

No inherited child ran `docker run`, restarted PostgreSQL, or recreated the
database before capture. Each child container's Docker `StartedAt` had to
match the inherited golden parent.

### Repeatability

Two earlier code-equivalent live runs produced the same directional result:

~~~text
run 36633487698:
  current median    13,983 ms
  inherited median   5,904 ms
  speedup             2.368x

run 36633632761:
  current median    14,422 ms
  inherited median   6,421 ms
  speedup             2.246x
~~~

Across all three five-pair experiments, inherited running PostgreSQL remained
materially faster than starting PostgreSQL after each child fork.

The canonical artifact-producing run is used for the recorded v1 summary rather
than pooling samples after the fact.

### Correctness boundary

BOXD4.4 independently proved write isolation, CHECKPOINT behavior, child restart
durability and unchanged parent state for the same running PostgreSQL fork
mechanism. BOXD4.5 deliberately keeps extra database mutations out of the timed
product path so the latency comparison measures lifecycle work rather than a
synthetic isolation workload.

### Decision

For the Boxd experimental provider, a pre-running PostgreSQL golden is now the
preferred hypothesis for the next whole-provider benchmark.

This does not yet promote Boxd into normal placement. The next benchmark must
compare the optimized steady-state Boxd path against the hosted managed executor
using the same fixture and keep cold golden construction/amortization explicit.
