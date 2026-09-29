# Implementation Plan 0027: Collapsed Boxd Post-fork Critical Path v1

Status: complete - collapsed post-fork critical path proven live

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


## Live result - 2026-09-30

Canonical final-code benchmark:

~~~text
GitHub Actions run: 36646891578
commit:             1e318275b5e39e23bb216901d92e490d3d5ff38b
artifact:           boxd-provider-benchmark-v3-36646891578-1
artifact id:        11068079369
sha256:             b496ccc939345fe5664dc98666f21c48656a80b0c91d3dd52de1198e2750d4b8
retention:          14 days
~~~

All ten provider samples produced:

~~~text
decision=regression
merge_recommendation=block
finding=NEW_RUNTIME_ERROR
~~~

### Primary result

| Pair | First | Hosted | Collapsed Boxd |
| ---: | --- | ---: | ---: |
| 1 | hosted | 2,689 ms | 4,019 ms |
| 2 | Boxd | 2,252 ms | 3,155 ms |
| 3 | hosted | 2,238 ms | 3,105 ms |
| 4 | Boxd | 2,274 ms | 2,906 ms |
| 5 | hosted | 2,205 ms | 3,079 ms |

Summary:

~~~text
hosted median          2,252 ms
collapsed Boxd median  3,105 ms
Boxd / hosted          1.379x
absolute median gap      853 ms
~~~

The first Boxd sample was again the slowest. The later four samples clustered
between 2.906 and 3.155 seconds.

### Improvement history

~~~text
BOXD3 Boxd v1        39,738 ms
BOXD5 optimized       6,509 ms
BOXD6 collapsed       3,105 ms

BOXD6 vs BOXD5         2.096x faster
BOXD6 vs BOXD3        12.798x faster
~~~

The hosted comparator stayed in the same broad range as prior benchmarks:

~~~text
BOXD3 hosted median    2,417 ms
BOXD5 hosted median    2,467 ms
BOXD6 hosted median    2,252 ms
~~~

### Collapsed phase evidence

Per-sample Boxd phases:

| Pair | Fork | Baseline role | Candidate role | Role critical | Cleanup |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,699 ms | 1,971 ms | 2,084 ms | 2,084 ms | 231 ms |
| 2 | 932 ms | 1,999 ms | 1,706 ms | 1,999 ms | 220 ms |
| 3 | 824 ms | 2,058 ms | 1,990 ms | 2,058 ms | 218 ms |
| 4 | 848 ms | 1,832 ms | 1,801 ms | 1,832 ms | 221 ms |
| 5 | 774 ms | 2,065 ms | 2,085 ms | 2,085 ms | 216 ms |

The old separate inherited PostgreSQL-ready phase is absent from the critical
path. PostgreSQL health and exact Docker StartedAt verification now execute
inside the same remote role command that checks out the revision, starts Node
and captures the scenario.

Baseline and candidate role elapsed values are both recorded, while only their
maximum contributes to the role critical path.

### Cold and amortized lifecycle

~~~text
create golden       2,119 ms
prepare golden     15,830 ms
cold setup total   17,949 ms
final cleanup         108 ms

steady-state median 3,105 ms
~~~

Amortized over a shared persistent golden:

| Executions | Amortized Boxd |
| ---: | ---: |
| 1 | 21,162 ms |
| 5 | 6,716.4 ms |
| 10 | 4,910.7 ms |
| 50 | 3,466.14 ms |

Cold golden construction remains a separate lifecycle concern rather than
steady-state PR latency.

### Repeatability

A code-equivalent pre-gofmt run `36646714258` also passed all five pairs:

~~~text
hosted median          2,483 ms
collapsed Boxd median  3,585 ms
Boxd / hosted          1.444x
BOXD6 vs BOXD5         1.816x faster
~~~

The two runs agree directionally: collapsing the post-fork critical path moves
the optimized Boxd execution from roughly 6-6.5 seconds to roughly 3-3.6
seconds on this fixture.

### Decision

The broad Boxd lifecycle architecture is no longer the dominant latency
problem for this fixture.

The canonical steady-state gap is now only 853 ms. Remaining Boxd time is
mostly:

- pair fork, especially first-use variance;
- one parallel role critical path of about 1.8-2.1 seconds;
- small provider cleanup.

Do not add more lifecycle machinery simply to chase the remaining sub-second
median gap.

The next investigation should combine:

1. economics per execution / per active hour;
2. first-fork warmup variance;
3. whether Boxd's persistent fork-native isolation and BYOC capabilities justify
   a modest steady-state latency premium;
4. placement policy based on workload characteristics rather than one global
   default provider.
