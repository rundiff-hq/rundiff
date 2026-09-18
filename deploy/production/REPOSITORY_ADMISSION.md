# Production repository admission

The first public GitHub App proof deliberately does **not** make the current long-lived executor a general multi-tenant compute service.

Customer bootstrap and Rails execution can run repository-controlled code. Until the disposable managed executor isolation described by RFC 0004 / #82 exists, the production control plane must fail closed to an explicit repository allowlist.

Configure exact GitHub repository full names:

```text
RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST=external-owner/proof-repository,another-owner/another-repository
```

Rules:

- production readiness fails when the allowlist is absent or empty;
- `*` is rejected in production;
- matching is exact `repository.full_name` matching, not prefix or glob matching;
- development/test remain unrestricted when the variable is absent;
- if the variable is configured in development/test, it is enforced there too;
- signed execution-trigger deliveries outside the allowlist are persisted for audit, marked `ignored` with `repository_not_allowed`, and never enqueue execution;
- `pull_request` and `check_run.rerequested` use the same admission policy.

For the #75 cross-account proof, put only the selected external proof repository in the allowlist before the production control plane is allowed to become ready.

This is a temporary admission boundary. It should be removed or replaced only when arbitrary public installations execute in a disposable tenant-isolated environment rather than on a long-lived shared executor host.
