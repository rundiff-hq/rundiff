# Implementation Plan 0022: Long-lived Boxd SDK Session v1

Status: complete - long-lived SDK session proven live

Tracking issue: #224

## Goal

Remove process-per-operation Node and Boxd SDK setup from repeated provider calls while preserving the existing RunDiff compute contracts.

BOXD4.1 proved persistent golden reuse, but the live proof still measured:

~~~text
Ensure(create)  ~9.8 s
Ensure(reuse)   ~3.65 s
~~~

The reuse path only needs machine lookup plus ready-marker verification, so multi-second overhead is dominated by the current transport shape rather than golden preparation.

## Current transport

~~~text
Go operation
  -> start node
  -> construct Boxd SDK client
  -> authenticate/session setup
  -> one operation
  -> close SDK
  -> exit node
~~~

That happens independently for Get, Exec, Fork, Remove and Create.

## Target transport

~~~text
Go SDK
  |
  | serialized JSONL
  v
one Node process
one Boxd SDK client
  |
  +--> Get
  +--> Create
  +--> Fork
  +--> Exec
  +--> Remove
~~~

The internal compute.Provider and GoldenManager APIs do not change.

## Protocol

Each request is one JSON line:

~~~json
{"id":1,"request":{"operation":"get","name":"..."}}
~~~

Each response is one JSON line:

~~~json
{"id":1,"response":{"machine":{"name":"..."}}}
~~~

or:

~~~json
{"id":1,"error":"provider error detail"}
~~~

Requests are serialized under one Go mutex. Response ids must match exactly. A malformed response or id mismatch terminates the session because continuing would risk request/response desynchronization.

## Error semantics

- Boxd typed NotFound remains structured notFound=true and becomes ErrMachineNotFound.
- customer command non-zero exit remains ExecResult.ExitCode.
- provider/auth/network errors remain provider errors and do not require the Node session to exit.
- caller context cancellation terminates the whole session process.

The cancellation rule is deliberate: after abandoning one in-flight serialized request, RunDiff cannot safely assume the next stdout line belongs to a later request. A future multiplexed transport may support per-request cancellation.

## Lifecycle

NewSessionSDK starts one Node bridge process. SDK.Close closes stdin, allows the bridge to close the SDK client, and waits for process exit. A bounded fallback kill prevents shutdown from hanging indefinitely.

The existing short-lived NewSDK remains available for fallback, comparison, and migration.

## Live proof

Use one long-lived client to:

1. lookup/remove any stale proof golden;
2. Ensure one prepared golden;
3. Ensure the same golden twice more;
4. prove preparation ran once;
5. prove the same machine and prepared state survive;
6. record create and two reuse timings;
7. remove the proof golden;
8. close the SDK session.

No latency threshold is an acceptance condition in v1. The timing is evidence for the next optimization decision, not a flaky performance test.

## Acceptance

- shared Node operation implementation used by both bridge modes;
- JSONL session bridge with one SDK client;
- Go session runner preserves request/response ordering;
- SDK Close support;
- typed NotFound preserved;
- workload exit codes preserved;
- unit lifecycle tests require no provider network;
- live persistent golden session proof;
- normal CI green;
- no Request v1 / Result v1 changes.


## Live evidence - 2026-09-29

GitHub Actions Boxd provider proof run `36598445624` completed successfully on
the long-lived-session branch.

The same workflow re-proved:

~~~text
copy-on-write fork isolation   PASS
persistent golden reuse        PASS
long-lived SDK session reuse   PASS
real Behavioral Diff           PASS
product result                 regression -> block
finding                        NEW_RUNTIME_ERROR
~~~

Observed golden timings:

| Path | Operation | Time |
| --- | --- | ---: |
| BOXD4.1 one-shot bridge | reuse | ~3,654 ms |
| current one-shot control in this run | reuse | 3,089 ms |
| BOXD4.2 long-lived session | first reuse | 386 ms |
| BOXD4.2 long-lived session | second reuse | 467 ms |

The session reuse path therefore reduced the measured repeated golden
lookup+ready-marker verification from multi-second one-shot calls to
sub-second calls in this proof. Relative to the BOXD4.1 live observation,
386 ms is about 9.5x lower latency and 467 ms is about 7.8x lower latency.

The session proof also reduced initial golden Ensure in this small proof:

~~~text
one-shot Ensure(create)    8,871 ms
session Ensure(create)     1,889 ms
~~~

This comparison is directional rather than a production SLO: the provider
service, network and VM state can vary between calls.

In the real Behavioral Diff proof from the same workflow:

~~~text
provider.create.golden_ready_ms = 2295
provider.fork_pair_ready_ms     = 2016
product.behavioral_diff         = block
product.finding                 = NEW_RUNTIME_ERROR
provider.cleanup.pair_ms        = 330
provider.cleanup.golden_ms      = 165
~~~

The earlier BOXD3 benchmark measured pair fork readiness around 4.47 s median
with process-per-operation transport, so the ~2.02 s live observation is also
consistent with removing repeated bridge/session setup. It is not yet a formal
five-pair benchmark result.

### Decision

Keep the long-lived SDK session as the preferred Boxd transport for
fork-native experiments. Keep the one-shot bridge as a bounded
reference/fallback during the spike.

BOXD4.3 should now address the next structural limitation: the provider session
serializes operations and `compute.ForkPair` creates baseline and candidate
sequentially. Parallel pair fork must preserve partial-failure cleanup and
cancellation semantics.
