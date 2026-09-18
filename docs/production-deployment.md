# Production deployment entry point

The concrete first production deployment contract lives in [`deploy/production/README.md`](../deploy/production/README.md).

It turns the runtime-role design in `docs/production-runtime.md` into a runnable two-host topology for #75:

```text
app.rundiff.com      -> control_plane web + Solid Queue worker
executor.rundiff.com -> executor_service + disposable-subject PostgreSQL authority
```

Both roles deploy the same immutable GHCR SHA image. They use separate Cloudflare Tunnel credentials and separate Rails secrets. Only the control plane receives GitHub App credentials; only the executor receives the server side of the executor service token.

Production GitHub App registration is intentionally two-phase because the control-plane readiness gate requires App credentials that do not exist until registration completes. See the deployment README for the bootstrap and final readiness sequence.

Provider-specific host provisioning/IaC is deliberately a follow-up to this runnable contract. The trust boundary and process topology should remain the same whether the first two hosts are created manually, with Terraform, or later moved to Kubernetes.
