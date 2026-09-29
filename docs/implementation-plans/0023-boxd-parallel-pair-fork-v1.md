# Implementation Plan 0023: Parallel Boxd Pair Fork v1

Status: complete - parallel pair fork proven live

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


## Live evidence - 2026-09-29

GitHub Actions Boxd provider proof run `36610609023` passed on commit
`7508a82b25e5bd031a6518372530f97ce6c51e0d`.

The workflow re-proved:

~~~text
one-shot COW isolation              PASS
persistent golden reuse             PASS
long-lived SDK session reuse        PASS
parallel pair fork isolation        PASS
parallel pair fork benchmark        PASS
real Behavioral Diff                PASS
product result                      regression -> block
finding                             NEW_RUNTIME_ERROR
~~~

A single sequential-vs-parallel comparison was noisy:

~~~text
sequential pair ready   1625 ms
parallel pair ready     2085 ms
~~~

That is why BOXD4.3 does not use a one-shot timing as the decision signal.

The same live workflow ran five alternating sequential/parallel samples against
the same provider and fixture:

| Sample | First | Sequential | Parallel |
| ---: | --- | ---: | ---: |
| 1 | sequential | 1900 ms | 2159 ms |
| 2 | parallel | 1852 ms | 963 ms |
| 3 | sequential | 1716 ms | 974 ms |
| 4 | parallel | 1705 ms | 968 ms |
| 5 | sequential | 1847 ms | 938 ms |

Summary:

~~~text
sequential median = 1847 ms
parallel median   =  968 ms
speedup           = 1.908x
~~~

The alternating order matters because it reduces bias from transient provider
warmth, parent state and network conditions. This is still a small live sample,
not a production latency SLO.

The real Behavioral Diff proof was also moved through the PairSDK capability,
so the product path itself exercised parallel pair fork:

~~~text
provider.create.golden_ready_ms = 2236
subject.golden_prepare_ms       = 10860
provider.fork_pair_ready_ms     = 2264
scenario.baseline_capture_ms    = 6213
scenario.candidate_capture_ms   = 6395
product.behavioral_diff         = block
product.finding                 = NEW_RUNTIME_ERROR
execution.total_ms              = 28255
provider.cleanup.pair_ms        = 340
provider.cleanup.golden_ms      = 165
~~~

The product proof preserved Capture v1 -> existing comparison -> Result v1
semantics and the expected blocking regression.

### Decision

Keep provider-capability-based parallel pair fork for Boxd experiments.

Do not generalize concurrency into the base Provider interface. Providers that
do not implement PairForker keep the previous sequential behavior.

The next fork-native experiment should target mutable runtime preparation,
especially whether a pre-running PostgreSQL state can be safely inherited and
then diverge independently after fork. That is BOXD4.4.
