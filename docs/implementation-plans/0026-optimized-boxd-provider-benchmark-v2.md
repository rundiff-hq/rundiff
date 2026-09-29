# Implementation Plan 0026: Optimized Boxd Provider Benchmark v2

Status: complete - optimized whole-provider benchmark recorded

Tracking issue: #235

## Goal

Rerun the original hosted-versus-Boxd provider benchmark after the BOXD4
fork-native optimizations, while preserving the original comparator semantics.

The question is now:

~~~text
For the same known RunDiff behavioral regression,
how does the optimized steady-state Boxd execution path compare
with the hosted managed Go executor path?
~~~

## Fixture and product result

Same fixture and immutable SHAs as VS20 and VS25:

~~~text
repository: rundiff-hq/example-node-express-postgres
baseline:   e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb
candidate:  a1663f54380e3a117989ebc6f1ab8f525f6bed4e
~~~

Every sample must independently produce:

~~~text
decision=regression
merge_recommendation=block
finding=NEW_RUNTIME_ERROR
~~~

## Hosted comparator

Unchanged from VS20:

~~~text
rundiff-executor run-local
~~~

running on the same GitHub-hosted Ubuntu 24.04 benchmark job.

The hosted timing includes executor runtime but excludes:

- GitHub queue time;
- control-plane dispatch;
- lease/heartbeat network;
- GitHub Check publication.

The same dependency cache root is reused across hosted samples.

## Optimized Boxd comparator

The Boxd comparator now uses all proven BOXD4 primitives together:

~~~text
one benchmark process
  |
  +-- one long-lived PairSDK
  |
  +-- one isolated golden VM
        |
        +-- fixture cloned
        +-- npm dependencies installed
        +-- RunDiff sensor installed
        +-- postgres:16-alpine pulled
        +-- PostgreSQL already running + healthy
        +-- CHECKPOINT complete
              |
              v
       repeated paired execution
              |
       parallel baseline/candidate fork
              |
       verify inherited PostgreSQL
              |
       start only revision-specific Node app
              |
       Capture v1 -> comparison.Pair -> Result v1
              |
       cleanup child pair
~~~

The golden and SDK sessions remain alive across all Boxd samples.

## Benchmark agent

The benchmark-only live test acts as a JSONL agent over stdin/stdout.

It owns:

- PairSDK lifecycle;
- golden lifecycle;
- running PostgreSQL;
- per-sample product execution.

The shell harness owns:

- hosted execution;
- provider alternation;
- cross-provider wall-clock timing;
- raw evidence collection;
- final report generation.

This keeps benchmark machinery out of the production package/API while still
measuring a genuinely persistent provider path.

## Sampling

Five paired samples on one GitHub-hosted benchmark job:

~~~text
pair 1: hosted -> Boxd
pair 2: Boxd  -> hosted
pair 3: hosted -> Boxd
pair 4: Boxd  -> hosted
pair 5: hosted -> Boxd
~~~

No Boxd golden recreation and no SDK recreation is allowed between samples.

## Timing boundaries

### One-time Boxd cold cost

Record separately:

- golden create;
- golden preparation including starting PostgreSQL;
- final golden cleanup.

### Steady-state sample

Record:

- provider round-trip wall time;
- internal fork-to-cleanup total;
- pair fork ready;
- inherited PostgreSQL ready verification;
- baseline capture;
- candidate capture;
- comparison;
- pair cleanup.

The primary cross-provider comparator remains shell-measured `wall_ms`.

## Amortization

Report steady-state Boxd median plus one-time cold lifecycle amortized over:

~~~text
N = 1, 5, 10, 50 executions
~~~

Formula:

~~~text
(cold create + cold prepare + N * steady-state median + final cleanup) / N
~~~

This prevents a persistent provider from being compared as if its reusable
golden preparation occurred on every PR.

## Historical reference

VS20 / BOXD3 canonical run:

~~~text
run:                   36587660042
hosted median:              2417 ms
old Boxd median:           39738 ms
old Boxd / hosted:         16.44x
~~~

The v2 report records the optimized Boxd speedup versus that old implementation,
but does not assume the hosted median remains identical across dates.

## Claim discipline

The result applies to this exact fixture, benchmark job shape and measured
provider executions.

It does not by itself answer:

- provider queue latency;
- control-plane dispatch latency;
- production cost;
- every PostgreSQL topology;
- every customer workload;
- whether Boxd should become the default provider.

Placement/economics decisions happen only after the measured v2 evidence is
available.

## Acceptance

- five alternating hosted/Boxd pairs;
- one Boxd golden across all Boxd samples;
- one PairSDK across all Boxd samples;
- inherited running PostgreSQL in every Boxd sample;
- same Capture v1 / Result v1 semantics;
- same blocking NEW_RUNTIME_ERROR on both providers;
- raw evidence + JSON report;
- cold, steady-state and amortized Boxd views;
- direct historical comparison to BOXD3;
- normal CI credential-free;
- final benchmark workflow manual-only.


## Live result - 2026-09-30

The canonical final-code benchmark is GitHub Actions run `36645026663` on
commit `b172efbe5ac0669c7394ae93bdb054d160e1834d`.

Artifact:

~~~text
boxd-provider-benchmark-v2-36645026663-1
artifact id: 11068012328
retention: 14 days
sha256: f783d3b964d8ed99a42d641328cd85f1665406665d2d30d40a55d88383657efb
~~~

All ten provider samples produced:

~~~text
decision=regression
merge_recommendation=block
finding=NEW_RUNTIME_ERROR
~~~

### Primary steady-state result

| Pair | First | Hosted | Optimized Boxd |
| ---: | --- | ---: | ---: |
| 1 | hosted | 2,993 ms | 7,856 ms |
| 2 | Boxd | 2,468 ms | 6,440 ms |
| 3 | hosted | 2,452 ms | 6,844 ms |
| 4 | Boxd | 2,464 ms | 6,314 ms |
| 5 | hosted | 2,467 ms | 6,509 ms |

Summary:

| Path | n | Median | p95 | Min | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hosted managed Go | 5 | 2,467 ms | 2,993 ms | 2,452 ms | 2,993 ms |
| Optimized Boxd | 5 | 6,509 ms | 7,856 ms | 6,314 ms | 7,856 ms |

~~~text
optimized Boxd / hosted median = 2.638x
absolute median gap            = 4.042 s
~~~

The benchmark-only agent's internal median was `6,506 ms`, only 3 ms below
the shell-observed `6,509 ms`, so JSONL control-channel overhead is negligible
for this result.

### Improvement versus BOXD3

The original BOXD3 canonical result was:

~~~text
run 36587660042
hosted median   =  2,417 ms
Boxd v1 median  = 39,738 ms
Boxd / hosted   = 16.44x
~~~

The optimized Boxd median is:

~~~text
6,509 ms
~~~

Therefore the measured Boxd implementation improved by:

~~~text
39,738 / 6,509 = 6.105x
~~~

The hosted path remained in the same approximate range across the two canonical
runs (2,417 ms then 2,467 ms), which makes the before/after provider comparison
especially useful for this fixture.

The original gap was reduced from approximately:

~~~text
37.321 s
~~~

to:

~~~text
4.042 s
~~~

### Optimized Boxd phase evidence

Per-sample phase ranges:

~~~text
parallel pair fork            1,038-2,387 ms
inherited PostgreSQL ready    1,695-1,823 ms
baseline capture              1,564-1,895 ms
candidate capture             1,554-1,761 ms
pair cleanup                    339-343 ms
comparison                         0 ms
~~~

The first Boxd sample carried a visibly slower fork (2,387 ms). Later samples
were roughly 1.0-1.25 s for pair fork, which is why the benchmark uses five
alternating samples instead of a single timing.

### Cold and amortized lifecycle

One-time lifecycle measured in the canonical run:

~~~text
create golden       2,569 ms
prepare golden     15,979 ms
cold setup total   18,548 ms
final cleanup         167 ms
~~~

Using the steady-state median of 6,509 ms:

| Executions sharing the golden | Amortized Boxd median |
| ---: | ---: |
| 1 | 25,224 ms |
| 5 | 10,252 ms |
| 10 | 8,380.5 ms |
| 50 | 6,883.3 ms |

This is why the persistent-golden provider model must distinguish cold
construction from steady-state PR execution.

### Repeatability

An earlier code-equivalent run `36644844056` completed successfully before
the final gofmt-only commit:

~~~text
hosted median          2,069 ms
optimized Boxd median  6,244 ms
Boxd / hosted          3.018x
Boxd vs v1 speedup     6.364x
~~~

Its artifact:

~~~text
boxd-provider-benchmark-v2-36644844056-1
artifact id: 11067589284
sha256: a11ba3310078d48a71df4311abd9c7a74f4f046dbe5f5fa761eb7a89bf8a0b2b
~~~

The absolute hosted timing varied between runs, but both whole-provider
experiments agree that the optimized Boxd path is now around 6-6.5 seconds and
is dramatically faster than the original 39.7-second implementation.

### Decision

BOXD4 succeeded architecturally: persistent golden state, long-lived SDK
sessions, parallel forks and inherited running PostgreSQL removed most of the
original Boxd execution overhead.

The optimized Boxd path is **not** yet a latency winner against the hosted
managed executor on this fixture. The canonical steady-state median remains
about 2.64x the hosted median.

Therefore:

- keep Boxd as an experimental/fork-native provider;
- do not make it the default placement based on latency;
- move the next investigation from broad lifecycle optimization to the
  remaining ~4-second steady-state gap and provider economics;
- evaluate whether the remaining Boxd latency buys capabilities that hosted
  execution does not provide, especially persistent fork-native state,
  isolation and BYOC-style placement.

Cost/economics, queue latency and control-plane/provider dispatch remain separate
questions and must not be inferred from this executor-runtime benchmark.
