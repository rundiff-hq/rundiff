# RunDiff production deployment

This directory defines the first production-realistic deployment contract for RunDiff.

## Topology

```text
GitHub
  -> https://app.rundiff.com
       -> Cloudflare Tunnel
       -> control_plane container
            -> durable PostgreSQL
            -> https://executor.rundiff.com
                 -> Cloudflare Tunnel
                 -> executor_service container
                      -> local PostgreSQL authority for executor ledger and disposable customer PostgreSQL subjects
                      -> disposable Git clone/worktrees
```

The two roles use the same immutable `ghcr.io/rundiff-hq/rundiff` image but must run on separate hosts or otherwise separate trust domains.

The control plane owns GitHub credentials and must use `RUNDIFF_EXECUTOR=remote`.
The executor must never receive the GitHub App private key, webhook secret, or remote-executor credentials.

## Why two hosts, not Kubernetes

The product boundary already requires isolation, but the first production proof does not require a scheduler. Two small Linux hosts keep the trust boundary explicit, operational debugging simple, and the path to later Kubernetes migration straightforward because the runtime contract is already containerized and role-driven.

Do not deploy `RUNDIFF_RUNTIME_ROLE=combined` in production; `/ready` rejects it.

## Operator quick path

The first production proof is operated through three repository entrypoints:

```bash
bash bin/release-production-image main
bash bin/init-production-role <control-plane|executor>
bash bin/deploy-production-role <control-plane|executor> deploy
```

`release-production-image` resolves the selected ref to an exact Git commit before dispatching the GHCR workflow and prints the immutable image tag `sha-<full-git-sha>`.

On both production hosts, check out that same release commit before initializing/deploying. The checked-out compose contract and the running image must describe the same revision.

`init-production-role` creates the required local env files from the committed examples with mode `0600`, never overwrites an existing file, and creates the control-plane `.secrets` directory with mode `0700`.

`deploy-production-role` validates required local files and Docker Compose configuration, then performs deterministic `pull`, `up -d --remove-orphans`, and `ps` operations. It also supports `pull`, `up`, `status`, `logs`, and `config` as explicit actions.

Host prerequisites are intentionally small:

- Linux host;
- Docker Engine;
- Docker Compose v2 (`docker compose`);
- outbound HTTPS to GHCR, Cloudflare, GitHub, and required package sources;
- a read-only repository checkout or equivalent copy of this deployment contract.

Cloud-provider provisioning and host package installation are kept outside this application repository for the first proof; the runtime deployment itself is provider-neutral.

## Immutable image inputs

On each host initialize the role instead of copying file names manually:

```bash
# Control-plane host
bash bin/init-production-role control-plane

# Executor host
bash bin/init-production-role executor
```

This creates `deploy/production/.env` from `images.env.example`. Fill immutable references:

```text
RUNDIFF_IMAGE_TAG=sha-<full-git-sha>
RUNDIFF_CLOUDFLARED_IMAGE=cloudflare/cloudflared@sha256:<digest>
RUNDIFF_POSTGRES_IMAGE=postgres@sha256:<digest> # executor host only
```

The application SHA must be identical on both roles. Pinning the supporting images makes rollback deterministic instead of silently following mutable Docker tags.

If the GHCR package is private, authenticate each host with a read-only package credential before deployment:

```bash
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
```

Do not place `GHCR_TOKEN` in any RunDiff application env file.

## Host 1: control plane

Initialization creates:

```text
deploy/production/.env.control-plane
deploy/production/.env.control-plane.tunnel
deploy/production/.secrets/
```

After GitHub App registration, place the returned private key at:

```text
deploy/production/.secrets/rundiff-github-private-key.pem
```

The directory is mounted read-only into the application container as `/run/secrets`. The private key itself therefore does not need to exist during the pre-registration bootstrap phase.

Required external dependency:

- durable PostgreSQL endpoint for `DATABASE_URL`

Required Cloudflare Tunnel route:

```text
app.rundiff.com -> http://rundiff:3000
```

Start or update:

```bash
bash bin/deploy-production-role control-plane deploy
```

## Host 2: executor

Initialization creates:

```text
deploy/production/.env.executor
deploy/production/.env.executor.postgres
deploy/production/.env.executor.tunnel
```

Use the same randomly generated service credential on opposite sides:

```text
control plane: RUNDIFF_REMOTE_EXECUTOR_TOKEN
executor:      RUNDIFF_EXECUTOR_SERVICE_TOKEN
```

The executor PostgreSQL password must match between `.env.executor.postgres`, `DATABASE_URL`, and `RUNDIFF_LOCAL_POSTGRES_URL`.

Required Cloudflare Tunnel route:

```text
executor.rundiff.com -> http://rundiff:3000
```

Start or update:

```bash
bash bin/deploy-production-role executor deploy
```

The executor route is service-authenticated. Do not configure GitHub App credentials on this host.

## Production repository admission

Until #82 provides disposable tenant isolation, production intentionally fails readiness unless `RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST` contains one or more exact `owner/repository` values. Wildcard admission is rejected.

For the #75 cross-account proof, configure exactly the external proof repository on the control plane before Phase B. See `REPOSITORY_ADMISSION.md` for the full temporary safety contract.

## Production bootstrap is intentionally two-phase

The production control plane cannot be fully ready before the production GitHub App exists because `/ready` requires the App id, webhook secret, readable private key, and production repository admission. Registration therefore has a narrow bootstrap phase rather than weakening readiness.

### Phase A: register the App

On the control plane:

1. set `RUNDIFF_GITHUB_APP_MANIFEST_ENV=production`;
2. set `RUNDIFF_ENABLE_GITHUB_APP_REGISTRATION=1`;
3. set `RUNDIFF_PUBLIC_URL=https://app.rundiff.com`;
4. provide a valid `SECRET_KEY_BASE`, `DATABASE_URL`, remote executor URL/token, and the other non-App production settings;
5. leave the not-yet-issued App id/webhook secret/private key absent;
6. deploy:

```bash
bash bin/deploy-production-role control-plane deploy
```

Expected state:

```text
GET /up                       -> 200
GET /github/app/register      -> 200
GET /ready                    -> 503 (expected until App credentials and admission exist)
```

Open:

```text
https://app.rundiff.com/github/app/register
```

Register `RunDiff` under the `rundiff-hq` organization. The production callback displays the one-time credentials; save them immediately to the control-plane secret store and write the private key to `deploy/production/.secrets/rundiff-github-private-key.pem`.

The browser registration/organization-owner confirmation is the one intentionally manual step.

### Phase B: become production-ready

Populate:

```text
RUNDIFF_GITHUB_APP_ID
RUNDIFF_GITHUB_CLIENT_ID
RUNDIFF_GITHUB_WEBHOOK_SECRET
RUNDIFF_GITHUB_PRIVATE_KEY_PATH=/run/secrets/rundiff-github-private-key.pem
RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST=<external-owner>/<proof-repository>
```

Then disable bootstrap registration again:

```text
RUNDIFF_ENABLE_GITHUB_APP_REGISTRATION=0
```

Redeploy the control plane and verify the complete topology:

```bash
bash bin/deploy-production-role control-plane deploy
bash bin/verify-production-topology \
  https://app.rundiff.com \
  https://executor.rundiff.com
```

Expected readiness payloads:

```json
{"status":"ready","role":"control_plane","errors":[]}
{"status":"ready","role":"executor_service","errors":[]}
```

Only after this gate is green should production GitHub webhook traffic be treated as live.

## Image release

`.github/workflows/release-image.yml` publishes the repository Dockerfile to GHCR on either:

- a manual `workflow_dispatch`, or
- a `v*` Git tag.

The preferred operator command is:

```bash
bash bin/release-production-image main
```

Every release publishes an immutable `sha-<full-git-sha>` tag. Deploy both roles from the same SHA tag so the Request/Result contracts cannot drift between the control plane and executor.

The GitHub Actions publisher uses the repository `GITHUB_TOKEN` with `packages: write` and does not require a separate package-write secret.

## Cloudflare Tunnel

Use two remotely-managed tunnels, one per host. Keep their tokens in separate `.env.*.tunnel` files so the tunnel credential is not injected into the RunDiff application container.

The first production proof intentionally uses Tunnel for stable HTTPS and avoids opening inbound application ports on either host.

## Secret split

| Secret / credential | Control plane | Executor |
| --- | --- | --- |
| `SECRET_KEY_BASE` | own value | different value |
| GitHub App private key | yes | **never** |
| GitHub webhook secret | yes | **never** |
| GitHub App id/client id | yes | no |
| repository allowlist | yes | no |
| remote/executor service token | client side | server side |
| Cloudflare Tunnel token | control-plane tunnel only | executor tunnel only |
| executor PostgreSQL password | no | yes |
| control-plane `DATABASE_URL` | yes | no |

The two Cloudflare Tunnel tokens and two Rails `SECRET_KEY_BASE` values must remain separate.

## Post-install verification

The production manifest points GitHub back to:

```text
https://app.rundiff.com/onboarding
```

After registration, verify that the public App installation page can be opened by an account outside `rundiff-hq` and that post-install setup lands on the onboarding page.

## Cross-account acceptance

The deployment is not considered product-proven until #75 is completed from a repository owned outside the `rundiff-hq` GitHub organization and both outcomes are observed:

```text
deliberate SQL regression -> DATABASE_QUERY_REGRESSION -> BLOCK
neutral candidate          -> no behavioral regression -> ALLOW
```

Record webhook delivery IDs, execution IDs, Check Run IDs, PR comment IDs, exact base/head SHAs, and install-to-first-review elapsed time in #75.
