# Production runtime

RunDiff production is intentionally split into two trust domains even though both roles currently ship from the same Rails codebase and container image.

```text
GitHub
  -> control plane
       -> durable RunDiffExecution
       -> HTTPS executor request + short-lived repository capability
            -> executor service
                 -> disposable Git clone/worktrees
                 -> behavioral evidence
       <- portable Result v1
  -> control-plane finalization
  -> GitHub Check + PR feedback
```

## Runtime roles

Set `RUNDIFF_RUNTIME_ROLE` explicitly in production.

### `control_plane`

Owns:

- GitHub App webhook ingress
- GitHub App private key and installation authentication
- durable product execution lifecycle
- execution leases, cancellation authority, stale guards and finalization
- minting short-lived repository clone capabilities
- behavioral policy and GitHub publication
- remote executor dispatch

The control plane must not execute customer repositories locally in production.

### `executor_service`

Owns:

- authenticated `/v1/executions` transport
- durable executor-request idempotency/cancellation ledger
- consumption of one short-lived repository-scoped clone capability
- disposable customer repository checkout
- subject environment discovery and execution
- portable `Result v1`

The executor service must not receive the GitHub App private key or webhook secret and must not be configured to recursively dispatch to another remote executor through the control-plane adapter.

### `combined`

`combined` mounts both route families and is the default convenience role in development/test.

Production `/ready` deliberately rejects `combined`. Deployment isolation is part of the product boundary, not only an operational preference.

## Container artifact

The repository root `Dockerfile` packages the same RunDiff codebase for either production role. Role selection remains runtime configuration rather than image-specific code.

```text
same image
  + RUNDIFF_RUNTIME_ROLE=control_plane
      -> GitHub-facing control plane

same image
  + RUNDIFF_RUNTIME_ROLE=executor_service
      -> isolated executor service
```

The image includes Git plus the PostgreSQL/SQLite build/runtime dependencies needed by RunDiff's currently supported Rails subject proofs. It deliberately does not yet define arbitrary customer dependency bootstrap or customer-authored setup hooks.

A reverse proxy or platform ingress should terminate public TLS. The control plane's configured remote executor URL is still required to use HTTPS in production readiness policy.

## Liveness vs readiness

```text
GET /up
GET /ready
```

`/up` is Rails process liveness.

`/ready` is the RunDiff deployment gate. It checks database connectivity plus role-specific production safety requirements. It returns `503` until the role is safe to receive traffic.

The readiness response contains only status, role and configuration error descriptions. It never returns secret values and database exceptions are reduced to their class rather than their message.

## Production environment matrix

| Setting | Control plane | Executor service |
| --- | --- | --- |
| `RUNDIFF_RUNTIME_ROLE` | `control_plane` | `executor_service` |
| `DATABASE_URL` | required | required |
| `RUNDIFF_PUBLIC_URL` | HTTPS required | do not need |
| `RUNDIFF_GITHUB_APP_ID` | required | do not need |
| `RUNDIFF_GITHUB_WEBHOOK_SECRET` | required | forbidden |
| `RUNDIFF_GITHUB_PRIVATE_KEY_PATH` | readable file required | forbidden |
| `RUNDIFF_EXECUTOR` | `remote` | must not be `remote` |
| `RUNDIFF_REMOTE_EXECUTOR_URL` | HTTPS required | forbidden |
| `RUNDIFF_REMOTE_EXECUTOR_TOKEN` | required | forbidden |
| `RUNDIFF_EXECUTOR_SERVICE_TOKEN` | do not need | required |
| `RUNDIFF_EXECUTOR_SERVICE_ADAPTER` | do not need | `git_clone` |
| `RUNDIFF_LOCAL_POSTGRES_URL` | do not need | PostgreSQL subject authority when applicable |

The control-plane `RUNDIFF_REMOTE_EXECUTOR_TOKEN` and executor-side `RUNDIFF_EXECUTOR_SERVICE_TOKEN` are the two ends of the same service-authentication credential. They should be injected into different deployments.

## Route surface

### Control plane

```text
POST /github/webhooks
GET  /github/app/register
GET  /github/app/manifest/callback
GET  /up
GET  /ready
```

### Executor service

```text
POST /v1/executions
POST /v1/executions/:execution_id/attempts/:attempt_number/cancel
GET  /up
GET  /ready
```

GitHub routes are not mounted on an `executor_service` deployment. Executor routes are not mounted on a `control_plane` deployment.

## GitHub App visibility

The production manifest `.github/app-manifest.json` is public because RunDiff v0.1 must be installable on customer GitHub accounts. Development and staging manifests remain private so internal environments are not distributable apps.

Public visibility does not imply GitHub Marketplace publication. A public GitHub App can be installed directly from its installation page while Marketplace remains a later product/distribution decision.

## CI topology proof

Pull requests from the RunDiff repository run a separate `remote_executor_topology` job.

The proof deliberately uses separate containers/processes:

```text
control-plane client container
  - has service credential
  - has short-lived repository capability
  - sends Request v1
        |
        | HTTP + out-of-band RunDiff-Repository-Authorization
        v
production executor container
  - RUNDIFF_RUNTIME_ROLE=executor_service
  - RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone
  - no GitHub App private key
  - no webhook secret
  - no remote-executor recursion config
  - /ready == 200
        |
        v
  disposable clone of exact PR base/head
        |
        v
  Result v1
```

The CI job-scoped GitHub token stands in for the production installation token only for this clone transport proof. It is repository-scoped, short-lived, sent through the same out-of-band capability header, and never injected into the executor service environment. Existing `RepositoryCapabilityProvider` tests separately prove the GitHub App installation-token minting contract.

After execution, CI reads the durable executor-request ledger and proves that the repository capability value was not persisted.

This validates the deployable transport/trust boundary without requiring a live production GitHub App installation in CI.

## Compatibility

`RUNDIFF_EXECUTOR_SERVICE=1` remains a compatibility signal. When `RUNDIFF_RUNTIME_ROLE` is absent, that flag resolves the deployment to `executor_service`.

New deployments should set `RUNDIFF_RUNTIME_ROLE` explicitly.

## Deployment gate

Before routing production traffic:

```text
control plane /up    -> 200
control plane /ready -> 200
executor /up         -> 200
executor /ready      -> 200
```

A successful liveness check with failed readiness is not a healthy RunDiff deployment.

## Still deliberately deferred

The deployable image and separate-process executor path are now proven. Remaining runtime/product boundaries include:

- arbitrary customer dependency/bootstrap policy beyond RunDiff-on-RunDiff compatible bundles
- hard worker/container termination
- worker-host heartbeat independent of control-plane queueing
- fork PR multi-repository capabilities
- arbitrary customer setup shell hooks and secret injection policy
- non-Rails subject runtimes
- first live production infrastructure apply, public control-plane/executor deployment, and external identity cutover (#92/#121/#75)
