# Implementation Plan 0004: Go Executor Vertical Slice 2

## Goal

Move execution ownership from provider-specific tuple claiming to exact-attempt assignment while preserving frozen Request v1 / Result v1.

VS2 introduces a renewable execution lease and cooperative cancellation channel between the Cloudflare control plane and the Go agent.

## Boundary

~~~text
provider bootstrap
  -> resolve execution_id + attempt_number
       |
       v
Go agent
  -> exact claim
  -> Request v1
  -> heartbeat / lease renewal
  -> execute
  -> Result v1
  -> exact result submission
~~~

The GitHub Actions tuple lookup remains temporary provider discovery only. It no longer needs to be the execution claim itself.

## Control-plane state

VS2 adds internal execution metadata:

- claimed_at
- heartbeat_at
- lease_expires_at
- cancelled_at
- cancellation_reason

These fields are control-plane lifecycle state and are deliberately absent from Request v1 / Result v1.

## Exact-attempt API

Protected executor-control endpoints:

~~~text
POST /api/executions/:execution_id/attempts/:attempt/claim
POST /api/executions/:execution_id/attempts/:attempt/heartbeat
POST /api/executions/:execution_id/attempts/:attempt/cancel
POST /api/executions/:execution_id/attempts/:attempt/result
~~~

The temporary GitHub Actions provider can resolve an exact assignment with:

~~~text
POST /api/execution-bridges/github-actions/resolve
~~~

Resolve does not claim work. Only the exact-attempt claim mutates lifecycle state.

## Lease semantics

An exact claim atomically transitions:

~~~text
available -> claimed
~~~

and writes a finite lease expiry.

A heartbeat renews only when:

- execution ID matches;
- attempt number matches;
- status is claimed;
- existing lease has not expired;
- overall execution timeout has not expired;
- GitHub authority still points at the same review when GitHub-managed.

A superseded or explicitly cancelled attempt is returned to the agent as a terminal heartbeat state. The Go agent cancels its local execution context and does not submit a late Result v1.

Result acceptance requires the exact claimed attempt and, for leased attempts, an unexpired lease.

## Compatibility

The old GitHub Actions `claim` endpoint remains temporarily available so VS1 production traffic can stay green while VS2 is tested and deployed.

Cutover happens only after the new Worker is deployed:

1. bridge resolves exact assignment;
2. Go agent exact-claims it;
3. Go heartbeats during execution;
4. Go submits Result v1 directly;
5. remove tuple-claim usage after production proof.

## Acceptance

- D1 exact claim is single-winner;
- lease expiry is finite;
- heartbeat renews only a live exact attempt;
- cancellation closes the lease;
- superseding records a cooperative cancellation reason;
- late Result v1 after cancellation is rejected;
- Go client uses exact execution ID + attempt on all managed endpoints;
- Go agent cancels local work on cancelled/superseded heartbeat;
- Go agent never submits a late result after lease loss;
- Request v1 / Result v1 remain unchanged;
- VS1 live bridge remains green until explicit production cutover.
