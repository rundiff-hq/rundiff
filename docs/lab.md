# Lab runner

RunDiff lab proofs use one runner-agnostic entry point:

```bash
bin/lab list
bin/lab run production --case topology
bin/lab run executor --case compose-service
bin/lab run executor --case isolated-compose-provider
bin/lab run onboarding --case sqlite
bin/lab run executor --case timeout
bin/lab run executor --case remote-topology
```

The contract is:

```text
bin/lab
  -> lab/<name>/<case>.sh
  -> deterministic stdout + artifacts
```

A lab case must not depend on GitHub Actions. The same command should run locally, on a GitHub-hosted ephemeral runner, or on a future self-hosted runner.

GitHub Actions is the default execution environment. A persistent Devbox should only be introduced when a proof has a demonstrated need for stable hardware/IP, large reusable caches, interactive debugging, or unusually long execution.

## Current cases

### production/topology

Runs the hermetic GitHub App -> control plane -> remote executor topology using the production Docker Compose lab. It preserves the current security assertions and stores driver, executor proof, Compose state and Compose logs below:

```text
tmp/lab/production/topology/
```

The legacy `bin/production-lab` entrypoint remains as a compatibility shim and forwards to `bin/lab run production --case topology`.

### executor/compose-service

Proves the explicit Docker Compose service lifecycle against the host Docker capability. The GitHub workflow only prepares Ruby and then invokes the same lab command that can be run locally.

Artifacts:

```text
tmp/lab/executor/compose-service/
```

### executor/isolated-compose-provider

Builds the executor and provider images, starts the isolated provider authority, proves the executor has no Docker socket/CLI authority, proves the customer UID cannot open the provider control socket, exercises the typed Compose lifecycle, checks for leaked Compose resources, and always captures provider/Docker state before cleanup.

Artifacts:

```text
tmp/lab/executor/isolated-compose-provider/
```

All disposable lab workflows keep `cancel-in-progress: true`; production mutation workflows remain separate and must never inherit that cancellation policy.


### onboarding/sqlite

Runs the arbitrary Rails + SQLite customer proof through the same lab contract used by production and executor experiments. It verifies automatic SQLite persistence discovery, candidate-only RunDiff configuration, portable tool-owned Rails capture, the expected database-query regression, no customer-owned RunDiff runtime files, and an unchanged control-plane lockfile.

Artifacts:

```text
tmp/lab/onboarding/sqlite/
```

### executor/timeout

Runs the focused HTTP adapter timeout tests for both connection and read timeouts. The assertions require the exact execution id, stable phases `remote_executor_connect` and `remote_executor_wait`, the underlying timeout class, and no secret leakage.

Artifacts:

```text
tmp/lab/executor/timeout/
```


### executor/remote-topology

Runs the deployable-image remote executor proof behind the universal lab contract. The lab owns the disposable Docker network, PostgreSQL container, executor container, readiness checks, request dispatch, secret-isolation assertions, executor-ledger capability check, artifacts, and cleanup.

GitHub Actions only maps pull-request context and the short-lived repository capability into generic `RUNDIFF_PROOF_*` environment variables before invoking:

```bash
bin/lab run executor --case remote-topology
```

The same case can be run outside GitHub Actions by supplying those generic proof variables. No GitHub Actions service container or host-network assumption is required.

Artifacts:

```text
tmp/lab/executor/remote-topology/
```
