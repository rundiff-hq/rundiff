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
5. the public GitHub App page is reachable and exposes RunDiff.

A successful result ends with:

```text
production_identity=verified
```

This command verifies what can be observed safely from outside. #121 remains the source of truth for settings that GitHub or Cloudflare do not expose through the application itself.

## Productization sequence

```text
repository hard rename
  -> external identity cutover (#121)
  -> production GitHub App + cross-account proof (#75)
  -> broader public onboarding
```
