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

After the production App is installed and #75 has one deliberate regression PR plus one neutral PR, collect the durable evidence bundle from the production control plane:

```bash
bin/collect-production-proof external-owner/proof-repo \
  --regression-pr 12 \
  --neutral-pr 13 \
  --output tmp/production-proof.json
```

The command uses the RunDiff App credentials already configured on the control plane. It mints installation-scoped GitHub tokens internally; no operator PAT is required and no token is written to the bundle.

It fails closed unless:

- the proof repository is owned outside `rundiff-hq`;
- the durable execution is completed;
- current GitHub base/head SHAs exactly match the recorded execution;
- the regression PR is `BLOCK` with a failing RunDiff Check;
- the neutral PR is `ALLOW` with a successful RunDiff Check;
- one exact Check Run matches the RunDiff execution id;
- one durable RunDiff PR comment exists;
- the webhook delivery matches installation/repository/PR/base/head.

The output contract is `schemas/production-proof-v1.schema.json` and is tracked by #123.

## Productization sequence

```text
repository hard rename
  -> external identity cutover (#121)
  -> production GitHub App + cross-account proof (#75)
  -> proof evidence bundle (#123)
  -> broader public onboarding
```
