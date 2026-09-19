# Rails repository onboarding

RunDiff v0.1 aims for a first Behavioral Review in a customer Rails pull request with minimal repository setup.

The repository-side path is proven end to end on a separate Rails + SQLite sandbox: a deliberate SQL regression produced `DATABASE_QUERY_REGRESSION` / `BLOCK`, while a neutral candidate produced `ALLOW`. That two-fixture sandbox remains a preproduction detector proof. Canonical production acceptance is stricter: one external PR must transition from GitHub-originated `BLOCK` to `ALLOW` after a normal fix push. The next live product boundary is the public hosted onboarding path at `/onboarding`.

The first onboarding slice keeps the configuration intentionally small. RunDiff discovers the Rails runtime and supported persistence automatically, while the repository declares the HTTP scenario that should be replayed against baseline and candidate.

## Hosted self-service flow

The intended customer path is:

1. Open the RunDiff `/onboarding` page.
2. Choose **Install RunDiff on GitHub** and grant the GitHub App access to the Rails repository.
3. Add a minimal `rundiff.yml` in the candidate branch.
4. Open or update a pull request.
5. RunDiff checks out the exact baseline and candidate revisions, bootstraps the supported Rails runtime, discovers PostgreSQL or SQLite, runs the same scenario on both sides, and publishes the Behavioral Review as a GitHub Check plus durable PR feedback.

GitHub App manifests use `/onboarding` as their post-install setup URL and redirect there again when repository access is updated. When GitHub setup parameters are present, the page may switch to a generic "continue setup" state and point the user directly to `rundiff.yml` plus the next pull request. The raw installation id is never rendered and no installation-specific data is loaded from those query parameters.

Those parameters are navigation hints only. RunDiff authorization continues to come from signed webhooks, the repository admission policy, and installation-scoped GitHub App access. A future authenticated installation dashboard must verify installation ownership through GitHub user authorization before exposing or mutating account-specific installation state.

The local `bin/setup-github-app` / manifest-registration flow remains a **RunDiff developer/operator bootstrap**, not a customer onboarding step. Customers should never need the launcher, manifest registration URL, webhook secret, private key, executor token, or local tunnel setup.

## Minimal configuration

Add `rundiff.yml` to the repository:

```yaml
version: 1
scenario:
  path: /orders/42
subject:
  persistence: auto
```

`subject.persistence: auto` is the default and may be omitted:

```yaml
version: 1
scenario:
  path: /orders/42
```

For this first slice, explicit persistence values are limited to:

```text
auto
postgresql
sqlite
```

Unsupported or ambiguous persistence fails explicitly instead of silently falling back to PostgreSQL.

## What RunDiff discovers

The local executor recognizes a Rails subject from the standard application boundary:

```text
config/application.rb
bin/rails
```

Persistence is discovered from `config/database.yml` first. If the adapter is not declared there, RunDiff falls back to Gemfile/Gemfile.lock evidence for `pg` or `sqlite3`.

The result resolves to the existing subject environments:

```text
Rails + PostgreSQL -> RunDiff::Subject::RailsPostgresEnvironment
Rails + SQLite     -> RunDiff::Subject::RailsSqliteEnvironment
```

The environment still owns preparation, isolated baseline/candidate state, runtime variables, and cleanup.

## A/B configuration ownership

RunDiff prepares exact baseline and candidate Git worktrees before resolving the run profile.

`rundiff.yml` is loaded from the candidate head once. Its scenario path is then applied to both executions:

```text
candidate rundiff.yml
       |
       +--> baseline scenario
       |
       +--> candidate scenario
```

This preserves one comparison contract even when the baseline commit did not contain RunDiff configuration yet. It also means adding `rundiff.yml` in the pull request can onboard an existing repository without a prerequisite commit on the default branch.

Persistence discovery remains per-worktree when `subject.persistence: auto` is used:

```text
baseline worktree  -> discover environment
candidate worktree -> discover environment
```

That avoids baking the candidate database implementation into the baseline execution and allows a persistence migration to be represented honestly.

## Current five-minute shape

The target remains one GitHub App installation plus one small declarative file. No RunDiff gem, GitHub Action, middleware, initializer, or repository-owned runtime is required for the proven Rails + SQLite path.

A fully public cross-account hosted onboarding still requires the production GitHub App to be deployed/registered and exercised from a different GitHub account or organization. The Development App remains private to the `rundiff-hq` owner and is only a proof environment.

## Deliberate limits

This slice does not add arbitrary setup commands, shell hooks, customer secrets, containers, MySQL, Sidekiq, non-Rails runtimes, or a general-purpose configuration language.

Those capabilities should be introduced from real onboarding requirements. In particular, customer-authored commands would require a separate trust and execution-policy design; `rundiff.yml` currently carries declarative scenario and persistence metadata only.

See #73, #65, #57 and `docs/subject-environments.md`.
