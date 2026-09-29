# Implementation Plan 0026: Optimized Boxd Provider Benchmark v2

Status: in progress

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
