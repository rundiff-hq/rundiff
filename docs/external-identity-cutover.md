# External RunDiff identity cutover

The repository hard rename is complete. A few identity-bearing systems live outside Git and must be changed manually before the production cross-account proof in #75.

The actionable tracker is **#121: Complete external RunDiff rename and production identity cutover**. Do not close #121 until all external systems use the canonical RunDiff identity.

## Canonical production identity

```text
Product             RunDiff
GitHub organization rundiff-hq
Main repository     rundiff-hq/rundiff
GHCR image          ghcr.io/rundiff-hq/rundiff
Domain              rundiff.com
Control plane       https://app.rundiff.com
Executor            https://executor.rundiff.com
Config              rundiff.yml
Environment prefix  RUNDIFF_
```

## Manual external systems

The following cannot be completed by a repository-only PR:

- existing GitHub App display names and actual App slugs;
- GitHub App Homepage, Webhook, Setup and callback settings;
- confirmation that the production App is public;
- Cloudflare zone ownership, DNS records and Tunnel routes;
- deployed GitHub Environment variables and secrets;
- production host-local environment files and secret files;
- operator workstation clone/remotes.

Credentials do not need rotation only because the display name changes. Rotate them only when required by the provider or by normal security policy.

## Machine verification after cutover

After production configuration is deployed, run:

```bash
RUNDIFF_GITHUB_APP_SLUG=<actual-production-app-slug> \
  bin/verify-production-identity
```

The verifier fails closed unless:

1. the public URLs are the canonical RunDiff production origins;
2. no pre-RunDiff environment-variable prefix is present in the invoking environment;
3. both production roles report healthy readiness;
4. the public onboarding page contains the RunDiff brand and no pre-RunDiff identity;
5. the public GitHub App page is reachable and exposes RunDiff;
6. the configured App credentials authenticate to the expected RunDiff App;
7. the live App name, slug, owner, external URL, permissions and subscribed events match the canonical contract;
8. the live App webhook points to `https://app.rundiff.com/github/webhooks`, uses JSON, and keeps TLS verification enabled.

A successful result ends with:

```text
production_identity=verified
```

The authenticated GitHub App portion uses the configured App ID and private key to call GitHub's App-level API. It never prints the JWT, private key, webhook secret, or installation token.

GitHub does not expose every settings-page field through this API, so #121 remains the source of truth for any residual settings that still require an organization-owner browser check. Cloudflare live state remains a separate provider boundary.

## Cross-account proof evidence

After the production App is installed, #75 uses one external pull request that first produces BLOCK and then, after a normal fix push, produces ALLOW.

Collect the durable evidence bundle from the production control plane immediately after the ALLOW revision:

```bash
bin/collect-production-proof external-owner/proof-repo \
  --pull-request 12 \
  --output tmp/production-proof.json
```

The command uses the RunDiff App credentials already configured on the control plane. It mints an installation-scoped GitHub token internally and authenticates as the App to verify GitHub's own webhook delivery history. No operator PAT is required and no token is written to the bundle.

It fails closed unless:

- the proof repository is owned outside `rundiff-hq`;
- an earlier completed BLOCK execution and a later completed ALLOW execution belong to the same PR, branch, baseline and App installation;
- the two revisions have different candidate SHAs;
- the BLOCK delivery is `pull_request/opened`;
- the ALLOW delivery is `pull_request/synchronize`;
- both delivery GUIDs are present in authenticated GitHub App webhook delivery history with matching repository, installation, action and successful HTTP delivery status;
- the current GitHub base/head exactly match the final ALLOW execution;
- one exact immutable Check Run matches each RunDiff execution id and candidate SHA;
- one durable RunDiff PR comment exists and currently shows ALLOW.

The durable comment is updated in place, so the earlier BLOCK is preserved by its execution, GitHub-confirmed webhook delivery and immutable Check Run rather than by a second comment.

The output contract is `schemas/production-proof-v2.schema.json`. The original evidence collector was tracked by #123; #158 upgraded that contract to the same-PR production acceptance required by #75.

## Productization sequence

```text
repository hard rename
  -> external identity cutover (#121)
  -> production GitHub App + cross-account proof (#75)
  -> proof evidence bundle (#123)
  -> broader public onboarding
```


## One-command cutover

For the final operator sequence, use `docs/production-cutover-runbook.md` and:

```bash
bin/verify-production-cutover --infra-repo ../infra
```

When the cross-account proof PR has transitioned from BLOCK to ALLOW, add `--proof-repo`, `--proof-pr`, and `--proof-output` from that runbook so the same command also produces the final evidence bundle.
