# Production cutover runbook

This is the final operator path for the first public RunDiff production proof.

## Prerequisites

- `rundiff-hq/rundiff` checked out at the intended release;
- `rundiff-hq/infra` checked out locally;
- production RunDiff control plane and executor deployed;
- GitHub App credentials configured on the control plane/operator environment;
- read-only Cloudflare API token configured with DNS Read plus Tunnel/Connector Read;
- `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_ZONE_ID` exported.

The command is deliberately read-only. It does not rename Apps, create DNS records, alter tunnels, rotate credentials, or deploy code.

## Identity and provider verification

Run from the application repository:

```bash
bin/verify-production-cutover --infra-repo ../infra
```

Stage order is fixed:

```text
RunDiff public identity/readiness
  -> authenticated GitHub App settings
  -> Cloudflare zone/DNS/tunnels/config
  -> proof not requested
```

Expected final line:

```text
production_cutover=verified
```

Any failed stage stops the command immediately.

## Same-org preproduction replay

Before the external-account proof, the installed App can be exercised against the canonical customer-like sandbox without making new commits:

```bash
bin/prove-github-app-demo \
  rundiff-hq/customer-rails-sandbox \
  --regression-pr 4 \
  --neutral-pr 5 \
  --wait 1200 \
  --output tmp/github-app-demo.json
```

PR #4 is the deliberate `BLOCK` regression and PR #5 is the neutral `ALLOW` case. This is not sufficient to close the cross-account acceptance criterion, but it proves the real App installation, signed webhook boundary, durable execution pipeline, remote executor, GitHub Check, and durable PR comment before moving to an external owner.

The sandbox repository must be explicitly admitted by `RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST`. The replay tool fails closed if the repository is not admitted or the App is not actually installed there.

## Cross-account proof

After the public App is installed on a repository owned outside `rundiff-hq`, create:

1. one PR with a deliberate behavioral regression that RunDiff marks `BLOCK`;
2. one neutral PR that RunDiff marks `ALLOW`.

Then run:

```bash
bin/verify-production-cutover \
  --infra-repo ../infra \
  --proof-repo external-owner/proof-repo \
  --regression-pr 12 \
  --neutral-pr 13 \
  --proof-output tmp/production-proof.json
```

The final stage calls `bin/collect-production-proof`, which correlates the durable webhook/execution records with the current GitHub PR heads, Check Runs and durable RunDiff comments.

## Success criteria

The cutover is complete only when:

- `production_cutover=verified` is printed;
- `/onboarding` exposes the `Tests passed. Behavior changed.` promise and `RunDiff / Behavioral Review` preview;
- the proof mode completes with both BLOCK and ALLOW evidence;
- `tmp/production-proof.json` conforms to `schemas/production-proof-v1.schema.json`;
- #121 and #75 can be closed with the resulting evidence.

## Safety

The runbook never requires an operator PAT. GitHub reads use the configured App identity/installation-scoped access. Cloudflare verification uses a read-only provider token. No token, private key, webhook secret or tunnel token is printed by the verification commands.
