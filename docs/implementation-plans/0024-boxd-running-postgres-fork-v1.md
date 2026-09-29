# Implementation Plan 0024: Running PostgreSQL Fork Proof v1

Status: in progress

Tracking issue: #230

## Goal

Determine whether Boxd can safely fork a VM while PostgreSQL is already running and produce two independent, durable database worlds.

This is a provider proof only. The real Behavioral Diff path remains unchanged until this experiment is green.

## Why this matters

BOXD3/4 evidence showed the remaining product path still spends several seconds per role starting mutable subject services. If PostgreSQL can be inherited already running, a fork-native golden can move service startup out of the per-execution critical path.

The experiment must prove more than immediate reachability. It must prove:

- the child inherited the already-running container rather than recreating it;
- baseline and candidate writes diverge independently;
- parent state does not change;
- WAL/checkpoint activity remains healthy;
- divergent child state survives PostgreSQL restart.

## Proof

~~~text
parent VM
  Docker running
  postgres:16-alpine running
  rundiff_bridge initialized
  golden row
  CHECKPOINT
      |
      v
parallel ForkPair
   /          \
baseline     candidate
   |            |
same StartedAt as parent
   |            |
writes A       writes B
CHECKPOINT     CHECKPOINT
   |            |
verify isolation
   |            |
restart PG     restart PG
   |            |
verify A       verify B
              /
       parent still golden
~~~

## Inheritance evidence

Before fork, record:

~~~text
docker inspect rundiff-postgres .State.StartedAt
~~~

Both children must report the exact same StartedAt before any child restart.

This does not by itself prove database correctness, but it distinguishes inherited running state from a child-side container recreation.

## Divergence evidence

Parent begins with:

~~~text
rundiff_fork_probe(id=1, value='golden')
rundiff_fork_events = empty
~~~

Baseline changes the probe to `baseline`, inserts 64 baseline events and issues `CHECKPOINT`.

Candidate independently changes the probe to `candidate`, inserts 64 candidate events and issues `CHECKPOINT`.

Expected worlds:

~~~text
parent     probe=golden     baseline_events=0   candidate_events=0
baseline   probe=baseline   baseline_events=64  candidate_events=0
candidate  probe=candidate  baseline_events=0   candidate_events=64
~~~

## Restart durability

After divergence, restart PostgreSQL in each child and wait for `pg_isready`.

The same divergent state must survive restart. Parent PostgreSQL must remain healthy and unchanged.

This catches failures that an in-memory-only post-fork check could miss.

## Timing evidence

Record:

- parent PostgreSQL preparation time;
- pair fork-ready wall time;
- inherited PostgreSQL ready time for each child;
- restart-ready time for each child.

No latency threshold is an acceptance condition in v1. Correctness comes first.

## Acceptance

- running PostgreSQL is healthy in parent before fork;
- both children inherit the same container StartedAt;
- no child `docker run` is performed after fork;
- baseline/candidate/parent database state diverges exactly as expected;
- CHECKPOINT succeeds in both children;
- child restart preserves divergent state;
- parent remains unchanged;
- all machines are cleaned up;
- normal CI remains credential-free;
- live proof remains opt-in/manual in final main;
- no Request v1 / Result v1 changes.
