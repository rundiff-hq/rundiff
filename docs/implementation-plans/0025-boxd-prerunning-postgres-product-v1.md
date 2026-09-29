# Implementation Plan 0025: Pre-running PostgreSQL Product Path v1

Status: in progress

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
