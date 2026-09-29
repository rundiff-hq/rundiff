# Implementation Plan 0024: Running PostgreSQL Fork Proof v1

Status: complete - running PostgreSQL fork proven live

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


## Live evidence - 2026-09-29

GitHub Actions Boxd provider proof run `36613904351` completed successfully on
commit `ca22b1bd411a4798507838edc85a41a1b3f226bd`.

The same workflow first re-proved the existing Boxd primitives:

~~~text
copy-on-write VM isolation          PASS
persistent golden reuse             PASS
long-lived SDK session reuse        PASS
parallel pair fork isolation        PASS
parallel pair fork benchmark        PASS
~~~

The running PostgreSQL proof then passed end to end.

Observed timings:

~~~text
postgres.parent_prepare_ms                    = 12567
provider.running_postgres_fork_pair_ready_ms =  2467
postgres.baseline_inherited_ready_ms          =  1707
postgres.candidate_inherited_ready_ms         =  1706
postgres.baseline_restart_ready_ms            =  3504
postgres.candidate_restart_ready_ms           =  3602
~~~

Both child containers reported the same pre-fork Docker `StartedAt` value as
the parent. No child-side `docker run` or PostgreSQL recreation occurred
before the inherited-ready checks.

The parent began with:

~~~text
probe=golden
baseline_events=0
candidate_events=0
~~~

After fork:

~~~text
baseline:
  probe=baseline
  baseline_events=64
  candidate_events=0

candidate:
  probe=candidate
  baseline_events=0
  candidate_events=64

parent:
  probe=golden
  baseline_events=0
  candidate_events=0
~~~

Both child databases accepted real writes and `CHECKPOINT`.

Each child PostgreSQL container was then restarted independently. After restart,
the same divergent state was still present in each child, while the parent
remained unchanged.

The proof emitted:

~~~text
postgres.running_fork_isolation=ok
postgres.running_fork_restart_durability=ok
~~~

The existing real Behavioral Diff proof also passed afterward:

~~~text
provider.fork_pair_ready_ms = 2457
product.behavioral_diff     = block
product.finding             = NEW_RUNTIME_ERROR
~~~

### Decision

Running PostgreSQL inheritance is viable enough to proceed to a product-path
experiment.

This proof does not yet mean every PostgreSQL topology is safe to fork. The
evidence currently covers:

- PostgreSQL 16 Alpine;
- one local Docker container;
- one database;
- no external replicas;
- no external network clients during the fork;
- no distributed storage;
- no active migration during the fork.

The next slice should move the known Node/PostgreSQL Behavioral Diff fixture to
a pre-running PostgreSQL golden and compare capture latency against the current
post-fork database-start path. Keep that change behind the Boxd experimental
provider path until repeated benchmark evidence exists.
