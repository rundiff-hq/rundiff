# Implementation Plan 0022: Long-lived Boxd SDK Session v1

Status: in progress

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
