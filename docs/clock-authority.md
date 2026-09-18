# Clock authority

RunDiff uses different clocks for different kinds of time.

## RunDiff-owned durable lifecycle

RunDiff is intentionally a PostgreSQL-backed control plane. Durable lifecycle transitions that participate in distributed correctness use PostgreSQL as their shared wall-clock authority.

The canonical database wall clock is:

```sql
clock_timestamp()
```

`clock_timestamp()` is deliberate. `CURRENT_TIMESTAMP` and `transaction_timestamp()` are transaction-stable, while leases, heartbeats, cancellation, and finalization need actual wall-clock progress even inside a long transaction.

Examples include:

```text
execution claim
heartbeat / lease renewal
lease expiry
finalization fence
cancellation
executor-service request claim / reclaim
executor-service request completion
GitHub webhook delivery claim / completion
```

Production lifecycle code should use `RunDiff::ClockAuthority.database_now` rather than sampling `Time.current` on whichever host happens to run the transition.

Generic Rails audit timestamps such as `created_at` and `updated_at` are not distributed timing evidence unless a lifecycle explicitly assigns them from the authoritative clock. For example, webhook claim assigns `updated_at` from the same database clock as `started_at` so that one transition has one clock domain.

## Process-local elapsed duration

Elapsed work inside one process uses a monotonic clock:

```ruby
Process.clock_gettime(Process::CLOCK_MONOTONIC)
```

Monotonic timestamps are only comparable when both endpoints belong to the same monotonic clock domain. Never subtract monotonic values produced by different hosts or different host boots.

## Active Job queue-stage evidence

Rails Active Job queue timing is customer runtime evidence, not RunDiff control-plane lifecycle timing.

The built-in Rails instrumentation captures a monotonic enqueue timestamp together with a host-boot clock-domain identifier. It also converts deliberate scheduling into a duration at enqueue time, while both scheduling timestamps still belong to the enqueuer's local clock domain.

At worker start:

```text
same host-boot clock domain
  -> queue_wait_ms from CLOCK_MONOTONIC
  -> scheduled_delay_ms from the declared enqueue-time duration
  -> dispatch_wait_ms = queue_wait_ms - scheduled_delay_ms

different or unknown clock domain
  -> queue-stage timing unavailable
```

This deliberately prefers missing evidence over fabricated cross-host precision. A future queue adapter may replace this fallback with backend-owned timing when it can prove that both boundaries share one trustworthy authority.

`RUNDIFF_MONOTONIC_CLOCK_DOMAIN_ID` is an internal runtime capability override. Set it only when the runtime or scheduler can guarantee that the participating processes really share one monotonic clock domain. Never set it merely to force cross-host queue timing to become available.

`RunDiffExecutionWorkItem.enqueued_at`, `started_at`, and `finished_at` remain lifecycle/audit fields for work tracking and quiescence. Behavioral queue-stage metrics must not be derived by subtracting those host wall-clock timestamps.

## Customer runtime evidence

The PostgreSQL rule above applies only to RunDiff-owned lifecycle state. It does not make PostgreSQL a requirement for customer software.

Customer timing is capability based:

```text
same-process elapsed work -> local monotonic duration
queue/backend timing      -> backend-owned timestamps when both boundaries share that authority
OTel timing               -> trustworthy span duration / causal timing
shared clock              -> only when an adapter can prove the clock domain
otherwise                 -> unavailable
```

A customer subject may use SQLite, MySQL, PostgreSQL, MongoDB, DynamoDB, an external service, multiple stores, or no database. Its persistence engine is not automatically a distributed clock authority.

## Testing

Lifecycle methods retain an explicit `now:` seam for deterministic unit tests. Production callers omit it and therefore use PostgreSQL-authoritative time.

Clock-skew tests should prove that changing a host's wall clock cannot change claim, lease, reclaim, cancellation, expiry, or queue-stage attribution when the relevant authoritative or monotonic clock is unchanged.
