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

Before the external-account proof, the installed App can be exercised against the canonical customer-like sandbox without making new commits.

First run the read-only preflight:

```bash
bin/verify-github-app-demo \
  rundiff-hq/customer-rails-sandbox \
  --regression-pr 4 \
  --neutral-pr 5
```

Then run the actual BLOCK + ALLOW proof:

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

After the public App is installed on a repository owned outside `rundiff-hq`, use one customer-shaped pull request:

1. open the PR with ordinary tests passing and a deliberate runtime SQL regression;
2. let GitHub's real `pull_request/opened` delivery produce `BLOCK / DATABASE_QUERY_REGRESSION`;
3. push the behavioral fix to the same PR branch;
4. let GitHub's real `pull_request/synchronize` delivery update that same PR to `ALLOW`.

Do not use `bin/replay-github-pr`, `bin/prove-github-app-demo`, curl, or a manually synthesized webhook for the canonical proof.

Then run:

```bash
bin/verify-production-cutover \
  --infra-repo ../infra \
  --proof-repo external-owner/proof-repo \
  --proof-pr 12 \
  --proof-output tmp/production-proof.json
```

The final stage calls `bin/collect-production-proof`. Production Proof v2 correlates both durable executions and webhook deliveries for that one PR, requires the first proof delivery to be `opened`, requires the final proof delivery to be `synchronize`, verifies the immutable Check Run attached to each exact candidate SHA, and requires the current GitHub PR head to match the final ALLOW revision.

The collector also authenticates as the production GitHub App and verifies each recorded `X-GitHub-Delivery` GUID against GitHub's own recent App webhook delivery history. Event, action, installation, repository and successful delivery status must all match. A RunDiff operator replay or another locally synthesized signed webhook therefore cannot satisfy the canonical production proof.

RunDiff maintains one durable PR comment and updates it in place. The proof bundle records that stable comment ID once, while the BLOCK revision remains durably evidenced by its execution, GitHub-confirmed webhook delivery and immutable Check Run.

## Success criteria

The cutover is complete only when:

- `production_cutover=verified` is printed;
- `/onboarding` exposes the `Tests passed. Behavior changed.` promise and `RunDiff / Behavioral Review` preview;
- the proof mode completes with both BLOCK and ALLOW evidence;
- `tmp/production-proof.json` conforms to `schemas/production-proof-v2.schema.json`;
- #121 and #75 can be closed with the resulting evidence.

## Safety

The runbook never requires an operator PAT. GitHub reads use the configured App identity/installation-scoped access. Cloudflare verification uses a read-only provider token. No token, private key, webhook secret or tunnel token is printed by the verification commands.
