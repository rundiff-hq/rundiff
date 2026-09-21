# Executor boundary

## Current implementation versus managed target

This document describes the currently proven portable Request/Result boundary and the current Rails executor-service implementation.

The accepted managed execution direction is a standalone Go Executor with host-level lifecycle, resource journal/sweeper cleanup, cgroup/namespace support, out-of-process sensors, and optional Firecracker isolation. That target is defined in RFC 0009.

The two documents are complementary:

~~~text
docs/executor.md
  -> current protocol/trust/lifecycle boundary

RFC 0009
  -> target managed host implementation
~~~

The Go migration must preserve the portable contracts, cancellation/finalization fencing, repository-capability isolation, and control-plane authority documented here.

RunDiff's Rails control plane owns GitHub authentication, durable execution state, stale guards, policy, cancellation authority, and publication. The executor owns only the act of producing behavioral evidence for one exact execution request.

```text
GitHub webhook
  -> Rails control plane
  -> durable RunDiffExecution
  -> executor request
  -> executor adapter
  -> executor result
  -> Rails stale guard
  -> finalization fence
  -> GitHub Check + PR comment
```

## Request/Result naming versus behavioral analysis

`RunDiff::Executor::Request` and `RunDiff::Executor::Result` remain the portable transport/execution contract.

They should not absorb the full behavioral analysis ontology.

Conceptually:

~~~text
Executor::Request
  -> execution
  -> Executor::Result
  -> Evidence
  -> Finding / Diagnosis / Relations
  -> Decision
~~~

Current schema v1 may contain nested historical `result` payloads. A future breaking schema revision may prefer a domain name such as `assessment`, but v1 is not renamed merely for naming purity.

See RFC 0010.


## Protocol v1 freeze

Executor protocol v1 is frozen as an executor-portable compatibility boundary before the managed Go executor implementation.

The canonical machine-readable contract and golden fixtures live at:

~~~text
protocol/executor/v1/request.schema.json
protocol/executor/v1/result.schema.json
protocol/executor/v1/fixtures/request.json
protocol/executor/v1/fixtures/result-allow.json
protocol/executor/v1/fixtures/result-block.json
protocol/executor/v1/fixtures/result-failure.json
~~~

Ruby and TypeScript contract tests consume the same fixtures. The Go executor must consume these fixtures before it is allowed to replace the Ruby reference executor.

Protocol v1 is **executor-portable, not SCM-neutral**. Its stable envelope is independent of the executor implementation, but the current optional `context` fields are GitHub-oriented compatibility metadata. A future GitLab, Bitbucket, Azure DevOps, or local-change connector should normalize change identity inside the control plane rather than teaching executors provider authentication or webhook semantics.

Readers may ignore unknown fields for forward compatibility. Producers must preserve `schema_version = "1"` and the documented required identity fields. Credentials, installation IDs, webhook delivery IDs, provider secrets, and clone capabilities remain outside the stable payload.

The nested historical `payload.result.merge_recommendation` is also a v1 compatibility shape, not a statement that the executor owns product policy. The long-term boundary remains:

~~~text
executor -> evidence/findings -> control-plane policy -> decision
~~~

The Go parity implementation may reproduce the v1 payload exactly; policy extraction can move further into the control plane in a later protocol revision without changing the execution transport prematurely.

## Portable request

The control plane converts `RunDiffExecution` into `RunDiff::Executor::Request` before dispatch. Schema version `1` contains:

```text
schema_version
execution_id
scenario_id
baseline_sha
candidate_sha
attempt_number
context.repository
context.pull_request_number
context.baseline_ref
context.candidate_ref
context.candidate_repository
```

The executor request deliberately excludes control-plane credentials and delivery internals. In particular it must not contain a GitHub App private key, installation token, webhook secret, installation ID, or webhook delivery ID.

A remote executor may receive a separate short-lived capability for cloning a private repository, but that capability is not part of the stable execution request contract.


### GitHub Actions bridge claim compatibility

The current GitHub Actions bridge discovers an available execution by the tuple:

~~~text
repository
pull_request_number
baseline_sha
candidate_sha
~~~

That lookup is a provider-specific bootstrap mechanism for the v1 GitHub Actions proof. It is **not** the target generic dispatch identity and must not become the managed executor contract.

Before one pull-request revision can schedule multiple scenarios through this bridge, discovery must either include `scenario_id` or, preferably, disappear entirely in favor of exact assignment.

The managed Go path must be addressed by the control plane with:

~~~text
execution_id
attempt_number
~~~

and then receive the corresponding Request v1. Executors must never scan for "a matching PR execution" when the control plane already owns the exact attempt identity.

## Portable result

`RunDiff::Executor::Result` schema version `1` is the return contract for every executor adapter.

A successful result contains the behavioral payload. A failed result contains only the source error class and message. Exception objects never cross the boundary.

```text
schema_version
status = succeeded | failed
payload
error_class
error_message
```

Adapters consume `RunDiff::Executor::Request` and return `RunDiff::Executor::Result`. `RunDiffExecutorJob` fails closed if an adapter returns an unversioned application payload instead of the portable result contract.

## Dispatch lifecycle

The GitHub orchestration job claims the durable execution and performs the first exact base/head check before enqueueing `RunDiffExecutorJob` with a plain request hash. It schedules the first heartbeat before executor dispatch so queue delay is inside the lease-protected lifecycle.

`RunDiffExecutorJob` reconstructs the request, invokes the selected adapter, and enqueues `GithubPullRequestExecutionFinalizeJob` with `Result.to_h`. If the adapter itself raises before returning a result, the job converts that transport or adapter exception into a failed portable result.

The finalizer is back inside the control-plane trust boundary. It renews the still-live lease, refreshes GitHub state, rejects stale results, and then atomically moves the exact running attempt to `finalizing`. That transition is the publication point of no return: cancellation can win before it, but cannot overwrite a finalizer that has already acquired the fence. Heartbeats continue while `finalizing` so a slow publication path remains leased.

```text
GithubPullRequestExecutionJob
  -> claim attempt + lease
  -> GitHub preflight
  -> schedule heartbeat
  -> Request.to_h
  -> RunDiffExecutorJob
       -> adapter(Request)
       -> Result.to_h
  -> GithubPullRequestExecutionFinalizeJob
       -> renew live lease
       -> GitHub stale guard
       -> running -> finalizing fence
       -> durable outcome
       -> GitHub publication
```

The executor job does not receive a GitHub App private key. Remote execution can receive a separate short-lived repository capability described below.


### Cloudflare-native managed lifecycle gap

The production Cloudflare v1 bridge has now proven webhook authority, D1 dedupe, stale-candidate superseding, exact Result acceptance, duplicate/conflicting Result behavior, timeout finalization, and GitHub publication. Its current execution states are intentionally narrower than the mature Rails reference lifecycle:

~~~text
available -> claimed -> result_received -> completed / infra_failure
~~~

The managed Go executor must not treat that proof-only claim model as the final host lifecycle. Before managed execution becomes canonical, the Cloudflare control plane needs an exact-attempt lifecycle equivalent to the Rails safety model, including durable attempt identity, claim/lease ownership, heartbeat/progress, lease expiry, cooperative cancellation, and a finalization fence.

This is a control-plane lifecycle extension, **not** a Request v1 / Result v1 schema change. The Go executor should be designed to support heartbeat and cancellation from its first managed-host slice.

## Execution leases and heartbeats

A successful claim creates a lease and records `heartbeat_at` plus `lease_expires_at`. The default lease is 30 minutes and can be configured with `RUNDIFF_EXECUTION_LEASE_SECONDS`.

`GithubPullRequestExecutionHeartbeatJob` renews only an exact attempt whose status is `running` or `finalizing` and whose existing lease is still live. Each successful heartbeat schedules the next heartbeat. A previous attempt, expired attempt, cancelled execution, or other terminal execution cannot renew or reschedule.

The default heartbeat cadence is one third of the execution lease. It can be configured with:

```text
RUNDIFF_EXECUTION_HEARTBEAT_INTERVAL_SECONDS=600
```

The interval must remain positive and shorter than `RUNDIFF_EXECUTION_LEASE_SECONDS`.

A result is accepted only while the lease is still live. The finalizer renews that lease before doing network publication work. A late result cannot revive an execution whose lease has already expired or which has been cancelled.

Production Solid Queue runs `GithubPullRequestExecutionLeaseReaperJob` every minute. It schedules an expiry job for overdue `running` or `finalizing` GitHub executions. The expiry transition is atomic: it succeeds only while the execution is still leased and its recorded lease is still expired. A concurrent heartbeat or finalizer renewal therefore wins safely and prevents expiry.

An abandoned execution becomes:

```text
status  = failed
outcome = infra_failure
failure = RunDiff::Executor::LeaseExpired: ...
```

The control plane then publishes the normal `INFRA_FAILURE` Check and comment. Publication is idempotent, and the expiry job can retry publication for an execution already terminal with the same lease-expiry failure.

## Cancellation lifecycle

Cancellation is an explicit durable outcome, not an infrastructure failure.

`RunDiff::Executor::Cancellation` atomically cancels only the exact current queued or running attempt. A successful cancellation records:

```text
status              = cancelled
outcome             = cancelled
cancelled_at         = <timestamp>
cancellation_reason  = <reason>
lease_expires_at     = nil
failure              = nil
```

If work had already been dispatched, `RunDiffExecutorCancellationJob` sends a cooperative cancellation request to the selected executor adapter. Delivery failure is logged but never rewrites the durable control-plane execution as `infra_failure`.

The finalizer and cancellation operation are fenced against each other. Cancellation can win while the execution is `queued` or `running`. Once the finalizer atomically moves the exact attempt to `finalizing`, the result has reached the publication point of no return and cancellation is rejected for that attempt.

A cancelled execution cannot publish a late behavioral result because finalization requires a live leased status and the exact finalization fence.

Hard process or container termination is intentionally separate from the durable cancellation contract. The current protocol guarantees cooperative notification, durable cancellation, and rejection of late results.

## Adapters

### Local

`RUNDIFF_EXECUTOR=local` selects the development adapter. It uses the exact-worktree + isolated PostgreSQL + Solid Queue implementation behind `RunDiff::Github::LocalPullRequestRunner` and wraps either its payload or exception in `RunDiff::Executor::Result`.

The local adapter accepts the cancellation protocol as a no-op because hard in-process interruption is outside this slice. The control-plane cancellation fence still prevents a late local result from becoming authoritative.

`RUNDIFF_GITHUB_EXECUTION_MODE=local` remains a temporary compatibility fallback for existing Development App setups.

### Remote HTTP

`RUNDIFF_EXECUTOR=remote` selects `RunDiff::Executor::HttpAdapter`.

Required settings:

```text
RUNDIFF_REMOTE_EXECUTOR_URL=https://executor.example.com/v1/executions
RUNDIFF_REMOTE_EXECUTOR_TOKEN=...
```

Optional transport settings:

```text
RUNDIFF_REMOTE_EXECUTOR_OPEN_TIMEOUT_SECONDS=5
RUNDIFF_REMOTE_EXECUTOR_READ_TIMEOUT_SECONDS=2100
```

The adapter sends one `POST` containing `Request.to_h` JSON and expects one `Result.to_h` JSON response. Execution requests include:

```text
Content-Type: application/json
Accept: application/json
Authorization: Bearer <executor service token>
Idempotency-Key: <execution_id>:<attempt_number>
RunDiff-Repository-Authorization: Bearer <short-lived repository capability>  # when available
```

The normal `Authorization` bearer authenticates the control plane to the executor service. It is not a GitHub token and is never added to the stable request body. The idempotency key gives a remote service a stable identity for duplicate transport submissions of the same attempt.

For a durable GitHub execution, the control plane can mint a second short-lived capability from the recorded installation. The token request is narrowed to the one repository and to `contents: read`. The resulting token is sent only in `RunDiff-Repository-Authorization`; it is not added to `Request.to_h` or `Result.to_h`.

A non-2xx response, invalid JSON, or invalid result schema becomes a transport `INFRA_FAILURE`; a valid failed `Result` preserves the remote worker's original error class and message through finalization.

Cancellation uses the same service-authentication credential but no repository capability:

```text
POST /v1/executions/:execution_id/attempts/:attempt_number/cancel
Content-Type: application/json
Authorization: Bearer <executor service token>

{"reason":"..."}
```

## Executor service role

The same codebase can be deployed in a separate executor-service role. New deployments select it explicitly with:

```text
RUNDIFF_RUNTIME_ROLE=executor_service
```

`RUNDIFF_EXECUTOR_SERVICE=1` remains a compatibility signal only when `RUNDIFF_RUNTIME_ROLE` is absent.

The service accepts:

```text
POST /v1/executions
POST /v1/executions/:execution_id/attempts/:attempt_number/cancel
```

and requires a dedicated bearer token:

```text
RUNDIFF_EXECUTOR_SERVICE_TOKEN=...
```

The control-plane `RUNDIFF_REMOTE_EXECUTOR_TOKEN` and the service-side `RUNDIFF_EXECUTOR_SERVICE_TOKEN` are the two ends of the same service-authentication credential. They are separate from GitHub App credentials.

Worker implementation is selected independently:

```text
RUNDIFF_EXECUTOR_SERVICE_ADAPTER=local
# or
RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone
```

`local` reuses an already-present checkout. `git_clone` requires the ephemeral repository capability and prepares a disposable Git workspace before invoking the same exact-worktree execution path.

This separation is intentional. A service deployment must not set `RUNDIFF_EXECUTOR=remote` and recursively call itself. It must not receive the GitHub App private key or webhook secret. The only GitHub credential it may receive is the per-execution, repository-scoped, contents-read clone capability.

### Durable transport idempotency and cancellation

Every executor service request is stored in `rundiff_executor_requests`, keyed uniquely by the HTTP `Idempotency-Key`. The ledger stores only the portable request, its digest, the portable result, service-side claim metadata, and cancellation metadata. It does not store either bearer token or the repository capability.

For the same idempotency key:

- the same completed request returns the previously stored `Result`
- a still-processing request returns conflict with `Retry-After`
- reuse with different request content is rejected
- an abandoned processing request can be reclaimed after its service-side claim lease expires
- a stale worker claim cannot overwrite the result after another worker has reclaimed the request
- cancellation is idempotent
- cancellation can be recorded before the execution request arrives
- a cancelled idempotency key cannot start work
- a worker result that races after cancellation cannot complete the cancelled claim
- a completed result cannot be replaced retroactively by cancellation

Cancellation and request acquisition use the same unique idempotency key as their race fence. If cancellation creates the durable record first, later request acquisition observes `cancelled` instead of executing. If execution creates the processing claim first, cancellation atomically moves it to `cancelled` and clears the claim token. Only one of completion and cancellation can win the conditional database transition.

Request digests canonicalize nested hash key ordering before hashing, so semantically identical JSON objects do not conflict only because their keys were reordered.

The service-side request lease defaults to 40 minutes:

```text
RUNDIFF_EXECUTOR_SERVICE_REQUEST_LEASE_SECONDS=2400
```

This lease protects transport idempotency. It is separate from the control-plane `RunDiffExecution` lease, which protects the product execution lifecycle.

### Repository clone capability

`RunDiff::Github::RepositoryCapabilityProvider` loads the durable execution by `execution_id`, reads the installation ID only inside the control-plane trust boundary, and asks GitHub for a narrowed installation access token:

```text
repository: exact request repository
permissions:
  contents: read
```

The token is deliberately out-of-band from request serialization. The executor controller parses it into `RunDiff::Executor::RepositoryCapability` and passes it to the selected worker adapter without adding it to `rundiff_executor_requests`.

`GitCloneAdapter` currently supports same-repository pull requests. It initializes a disposable repository, configures the normal GitHub HTTPS remote, and fetches the recorded base branch plus the PR head ref. Authentication is supplied to Git through process environment Git config, not embedded in the clone URL or Git command arguments. The workspace is removed after the attempt.

The adapter still reuses `LocalPullRequestRunner`, so arbitrary customer repositories must expose the execution/instrumentation surface expected by the current capture runtime. Generalized instrumentation packaging is a separate boundary from repository authorization.

## Trust boundary

The executor can report observations and execution failures. It does not decide whether a pull request may merge. The control plane remains authoritative for:

- exact recorded base/head identity
- stale checks before dispatch and finalization
- execution lease ownership, heartbeat, and expiry
- cancellation authority and finalization fencing
- behavioral outcome classification
- `INFRA_FAILURE` versus product regression versus cancellation
- retry eligibility and attempt counting
- GitHub publication
- minting the short-lived repository capability

The executor service role owns only:

- authenticating the control-plane service credential
- consuming the short-lived clone capability for repository access
- durable idempotency and cancellation fencing for one execution attempt
- acquiring a service-side worker claim
- producing `RunDiff::Executor::Result`

This keeps an executor replaceable: local process, container, VM, Kubernetes job, or another disposable worker can implement the same boundary.

## Remaining remote-runtime boundaries

Repository authorization, control-plane heartbeats, finalization fencing, and cooperative cancellation now have explicit contracts. The important remaining boundaries are:

1. worker-host progress/heartbeat transport independent of the control-plane queue
2. hard worker/container termination after cooperative cancellation
3. generalized subject instrumentation for customer stacks beyond the currently proven Rails path
4. fork pull requests, which require an explicit multi-repository capability model rather than reusing the base-repository capability

Deployment isolation and a real separate-process control-plane -> executor-service `git_clone` path are no longer remaining boundaries. They are exercised by `remote_executor_topology` and the hermetic Production Lab.

The live Development App infra-failure Re-run proof was completed in #35. The old workstation Development App clock-domain proof was later retired as a production gate in #51; current production acceptance is #75/#121.


## Dependency cache boundary

Dependency installation is supervised by the executor but remains owned semantically by the runtime's native package manager. Moving the managed executor from Ruby to Go therefore does not remove Bundler/npm/pip/uv/Go/Gradle/Maven caching.

Dependency Cache v1 derives a namespace-scoped, content-addressed identity from the runtime, package-manager version, platform/architecture, and committed lockfile digest. Baseline and candidate reuse one entry when that identity is identical; changed dependency identity produces a different entry.

~~~text
Go Executor
  -> Dependency Cache
       -> Ruby / Bundler
       -> Node / npm
       -> future runtime package managers
  -> prepared subject
  -> runtime sensor
~~~

Persistent managed/BYOC hosts may keep the cache on local storage. Ephemeral external-CI runners may restore/save the cache through their native cache adapter. The package manager still runs in frozen/locked mode and customer lockfiles remain immutable.

Prepared dependency directories are scoped by repository/tenant trust namespace. Do not share an arbitrary prepared customer environment across tenants solely because lockfile bytes match. Lower-level verified content-addressed package blobs may gain broader reuse in a future cache layer.

Performance evidence must label dependency bootstrap as cold or warm. The observed VS6 Bundler phases were 32.895 seconds cold for baseline and 0.316 seconds warm for candidate; this demonstrates cache importance, not a Go-versus-Ruby language speedup.

See ADR 0017 and implementation plan 0014.
