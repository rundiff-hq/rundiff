# Execution leases

RunDiff uses a durable lease on each claimed GitHub pull request execution so a worker that disappears cannot leave the control plane in a live state forever.

## Lifecycle

```text
queued
  -> claim!
  -> running + heartbeat_at + lease_expires_at
  -> heartbeat schedule starts before executor dispatch
  -> useful work remains live
     -> heartbeat renews the exact current attempt
  -> executor result
     -> finalizer renews the live lease
     -> running -> finalizing fence
     -> completed / failed / ignored

running/finalizing + expired lease
  -> production reaper
  -> lease expiry job
  -> infra_failure
  -> GitHub failed Check
  -> eligible for explicit re-run

queued/running
  -> cancellation request
  -> cancelled + outcome=cancelled
  -> lease closes immediately
  -> heartbeat stops
  -> executor cancellation is delivered cooperatively
  -> late result is ignored
```

`attempt_count` changes only when `claim!` succeeds. Lease expiry does not create a new attempt. A later GitHub re-run first requeues the same durable execution and the next successful claim increments the attempt.

## Heartbeats

`GithubPullRequestExecutionHeartbeatJob` is scheduled before executor dispatch. This covers both queue delay and a long synchronous remote HTTP request. A heartbeat renews only when all of these remain true:

- the execution still exists
- its status is `running` or `finalizing`
- the heartbeat carries the exact current `attempt_count`
- the existing lease is still live

A successful heartbeat schedules the next heartbeat. Terminal, cancelled, expired, or superseded attempts stop without rescheduling.

Heartbeat, cancellation delivery, lease reaping, and lease expiry run on the dedicated `control` Solid Queue queue. The blocking executor job remains on `default`. This isolation is required because a synchronous remote execution can occupy a default worker for minutes; lifecycle control must still be able to renew or cancel that execution even when `JOB_CONCURRENCY=1`.

The default heartbeat interval is one third of the execution lease. `RUNDIFF_EXECUTION_HEARTBEAT_INTERVAL_SECONDS` can override it, but the interval must remain positive and shorter than `RUNDIFF_EXECUTION_LEASE_SECONDS`.

## Cancellation

Cancellation is a terminal control-plane outcome, not an infrastructure failure. `RunDiff::Executor::Cancellation` atomically marks the exact active attempt as `status=cancelled`, `outcome=cancelled`, records `cancelled_at` and `cancellation_reason`, closes the lease, and then schedules cooperative cancellation delivery to the executor.

When a new runnable revision of the same pull request is dispatched, `ExecutionDispatcher` cancels any older queued or running revision before creating the new durable execution. The cancellation reason is `superseded_by_new_pull_request_revision`. This prevents obsolete work from continuing merely because the stale-result guard would reject it later.

For remote executors the control plane posts to the exact attempt cancellation endpoint. The executor service stores cancellation durably in `rundiff_executor_requests`. A cancellation can win before the execution request arrives, while the adapter is running, or after a duplicate delivery. Once cancelled, that idempotency key cannot start work or accept a late result.

Cancellation acceptance does not depend on the configured worker adapter being healthy. The executor service can record the cancellation tombstone even when execution itself is disabled or unavailable. Likewise, a control-plane cancellation-notification enqueue or delivery failure never rewrites the already-durable execution as `infra_failure`.

Cancellation and finalization are atomically fenced. Cancellation may win while an execution is `queued` or `running`. Once the exact attempt enters `finalizing`, publication owns the terminal transition and cancellation can no longer overwrite it.

Hard process or container termination remains a separate executor-host concern; the current contract guarantees durable cancellation, cooperative notification, and rejection of late results.

## Safety properties

- only leased `running` or `finalizing` executions with an overdue lease can be expired
- renewal and expiry are conditional database updates, so a renewed lease wins over an already-enqueued stale expiry job
- heartbeats from an older attempt cannot renew a newer attempt
- late executor results cannot finalize an expired, cancelled, or terminal execution
- cancellation and finalization have one atomic point of no return
- superseded pull request revisions are cancelled proactively
- an expired execution is classified as `infra_failure`, never as a behavioral regression
- a cancelled execution is classified as `cancelled`, never as `infra_failure`
- publication is retriable after the durable lease failure has already been recorded
- stale base/head state suppresses publication for an obsolete pull request execution

## Production schedule

`GithubPullRequestExecutionLeaseReaperJob` runs every minute in production and schedules `GithubPullRequestExecutionLeaseExpiryJob` for overdue GitHub executions.

The default lease is 30 minutes and can be changed with `RUNDIFF_EXECUTION_LEASE_SECONDS`.

The current heartbeat is control-plane scheduled on its own queue. A future worker-host heartbeat protocol can make liveness independent of the control-plane process and can carry progress metadata, but it must preserve the exact-attempt fencing rules above.
