# Lab runner

RunDiff lab proofs use one runner-agnostic entry point:

```bash
bin/lab list
bin/lab run production --case topology
```

The contract is:

```text
bin/lab
  -> lab/<name>/<case>.sh
  -> deterministic stdout + artifacts
```

A lab case must not depend on GitHub Actions. The same command should run locally, on a GitHub-hosted ephemeral runner, or on a future self-hosted runner.

GitHub Actions is the default execution environment. A persistent Devbox should only be introduced when a proof has a demonstrated need for stable hardware/IP, large reusable caches, interactive debugging, or unusually long execution.

## Current case

### production/topology

Runs the hermetic GitHub App -> control plane -> remote executor topology using the existing production Docker Compose lab. It preserves the current security assertions and additionally stores useful output under:

```text
tmp/lab/production/topology/
```

The legacy `bin/production-lab` entrypoint remains as a compatibility shim and forwards to `bin/lab run production --case topology`.
