# Implementation Plan 0023: Parallel Boxd Pair Fork v1

Status: in progress

Tracking issue: #228

## Goal

Reduce paired-environment startup latency by forking baseline and candidate concurrently without changing the base compute Provider contract.

BOXD4.2 proved that a long-lived SDK session removes repeated bridge/session setup:

~~~text
one-shot persistent golden reuse    ~3.65 s
session persistent golden reuse     386-467 ms
session Behavioral Diff pair fork   ~2.02 s
~~~

The remaining pair fork is still sequential because one session intentionally serializes requests.

## Provider capability

The base provider remains intentionally small. A provider may additionally implement `PairForker`. The generic `compute.ForkPair` dispatches to that capability when present and otherwise preserves the existing sequential fallback.

This avoids making concurrency or thread-safety a requirement of every future compute provider.

## Boxd implementation

Boxd uses two long-lived SDK sessions:

~~~text
PairSDK
  |
  +-- primary session   -> baseline fork
  |
  +-- secondary session -> candidate fork
             |
             v
        both ready
             |
             v
          Pair
~~~

Ordinary Provider operations delegate to the primary session. The secondary session exists for independent concurrent pair work.

## Failure cleanup

The child names are deterministic, execution-owned names supplied by the orchestrator before either fork starts.

If either fork fails or the caller cancels:

1. do not return a Pair;
2. create a fresh bounded one-shot provider path;
3. attempt removal of both deterministic child names;
4. treat provider NotFound as successful cleanup;
5. join fork and cleanup errors.

The fresh cleanup path is intentional. Context cancellation can terminate one or both long-lived sessions, so cleanup must not depend on those sessions remaining usable.

## Session lifecycle

`PairSDK.Close` closes both long-lived sessions.

If creation of the secondary session fails, construction closes the primary session before returning an error.

## Live proof

The opt-in proof must create one isolated parent, seed parent state, call generic `compute.ForkPair` with PairSDK, record pair-ready wall time, mutate baseline, prove candidate and parent still retain golden state, clean up all machines, and close both sessions.

The existing one-shot COW proof and real Behavioral Diff proof remain in the same workflow as regression guards.

## Acceptance

- generic sequential fallback unchanged;
- optional PairForker dispatch unit-tested;
- concurrent fork overlap unit-tested without provider network;
- partial failure removes both execution-owned child names;
- cancellation attempts the same deterministic cleanup;
- PairSDK closes both sessions;
- live parallel COW proof;
- pair-ready timing recorded;
- existing COW and Behavioral Diff proofs remain green;
- normal CI green;
- no Request v1 / Result v1 changes.
