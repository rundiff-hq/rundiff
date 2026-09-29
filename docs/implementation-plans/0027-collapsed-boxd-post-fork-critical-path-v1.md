# Implementation Plan 0027: Collapsed Boxd Post-fork Critical Path v1

Status: in progress

Tracking issue: #237

## Goal

Reduce the remaining optimized Boxd steady-state latency after BOXD5 without
changing Capture v1, Result v1, comparison semantics or provider placement.

BOXD5 canonical result:

~~~text
hosted managed Go median   2,467 ms
optimized Boxd median      6,509 ms
remaining median gap       4,042 ms
~~~

## Hypothesis

The BOXD5 Boxd path still pays for two avoidable serial boundaries after the
parallel VM fork:

1. inherited PostgreSQL health + StartedAt verification is a separate provider
   round trip before role capture;
2. baseline and candidate role captures execute sequentially.

Observed BOXD5 phase ranges:

~~~text
pair fork                   1,038-2,387 ms
inherited PostgreSQL ready  1,695-1,823 ms
baseline capture            1,564-1,895 ms
candidate capture           1,554-1,761 ms
pair cleanup                  339-343 ms
~~~

## Target critical path

~~~text
persistent running-PG golden
             |
       parallel pair fork
         /          \
baseline session    candidate session
       |                 |
single remote exec   single remote exec
  pg_isready           pg_isready
  StartedAt check      StartedAt check
  checkout baseline    checkout candidate
  start Node           start Node
  capture              capture
       |                 |
       +--------+--------+
                |
          comparison.Pair
                |
             cleanup
~~~

The expected parent PostgreSQL StartedAt is passed into each role script.
The script fails before starting the app if the inherited container does not
match the golden.

## Concurrency

Role capture uses the two already-existing PairSDK sessions:

- primary session: baseline;
- secondary session: candidate.

A small provider-independent test helper starts both functions concurrently and
collects both results before returning. It does not call testing.FailNow from
worker goroutines.

On cancellation, both role functions return their errors and the existing pair
cleanup remains responsible for deterministic child removal.

## Measurement

Rerun the BOXD5 whole-provider benchmark contract:

- one persistent golden;
- one persistent PairSDK;
- inherited running PostgreSQL;
- five alternating hosted/Boxd pairs;
- same fixture SHAs;
- same BLOCK / NEW_RUNTIME_ERROR result.

New per-sample evidence:

- pair fork;
- baseline role elapsed;
- candidate role elapsed;
- **role critical-path elapsed**;
- comparison;
- cleanup;
- total wall time.

The old separate inherited-ready phase should become zero because that
verification is now folded into each role's single remote execution.

## Historical references

~~~text
BOXD3:
  hosted median   2,417 ms
  Boxd median    39,738 ms

BOXD5:
  hosted median   2,467 ms
  Boxd median     6,509 ms
~~~

The v3 benchmark report records speedup both from BOXD3 and from BOXD5.

## Acceptance

- baseline/candidate role work demonstrably overlaps in a unit test;
- cancellation collects both role errors;
- PostgreSQL health and StartedAt are checked inside role capture;
- no extra inherited-ready provider RPC in the collapsed path;
- same valid Capture v1 and Result v1;
- five alternating hosted/Boxd benchmark pairs;
- direct BOXD5 comparison;
- normal CI credential-free;
- final benchmark workflow manual-only;
- no default-placement change from this slice alone.
