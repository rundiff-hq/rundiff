# GitHub App setup

RunDiff keeps one manifest per environment under version control:

- `.github/app-manifest.development.json` for `RunDiff Development`
- `.github/app-manifest.staging.json` for `RunDiff Staging`
- `.github/app-manifest.json` for production `RunDiff`

All manifests use `{{RUNDIFF_PUBLIC_URL}}` for callback and webhook URLs. The Rails bootstrap page resolves that placeholder at runtime.

## Unified launcher

From the repository root:

```bash
bash bin/setup-github-app
```

The launcher asks which environment to configure:

```text
1) Development
2) Staging
3) Production
```

You can also select the environment non-interactively:

```bash
bash bin/setup-github-app development
bash bin/setup-github-app staging
bash bin/setup-github-app production
```

The launcher verifies the project Ruby through `mise`, installs dependencies when needed, prepares PostgreSQL, starts the Rails bootstrap UI, starts or connects a Cloudflare Tunnel, verifies local and public health checks, and opens `/github/app/register`.

Development may use a Quick Tunnel when `api.trycloudflare.com` is reachable. Staging and production never use Quick Tunnels automatically and require a stable named tunnel or an explicitly supplied external public URL.

Useful overrides:

```bash
RUNDIFF_PUBLIC_URL=https://github-dev.example.com bash bin/setup-github-app development
RUNDIFF_TUNNEL_MODE=named bash bin/setup-github-app staging
RUNDIFF_TUNNEL_MODE=external RUNDIFF_PUBLIC_URL=https://app.example.com bash bin/setup-github-app production
```

Supported tunnel modes are `auto`, `quick`, `named`, and `external`. `quick` is restricted to Development.

## GitHub App registration

After the public endpoint is healthy, the launcher opens:

```text
https://<public-host>/github/app/register
```

The page renders the selected manifest and posts it to the GitHub organization App registration flow using a CSRF `state` value. GitHub redirects back to:

```text
/github/app/manifest/callback?code=...&state=...
```

RunDiff exchanges the one-time manifest code for the App credentials.

Development credentials are persisted locally under ignored `tmp/github-app/` files so the local webhook receiver can continue immediately. Staging and production credentials are shown on the callback page and must be saved to the target secret store.

## Permissions and events

All three manifests currently grant:

```text
Checks        read/write
Contents      read
Pull requests read/write
```

and subscribe to:

```text
pull_request
check_run
```

GitHub installation lifecycle deliveries are sent to GitHub Apps independently of the explicit event list.

## Webhook

The webhook endpoint is:

```text
POST /github/webhooks
```

It requires a valid `X-Hub-Signature-256` generated with `RUNDIFF_GITHUB_WEBHOOK_SECRET` and logs safe delivery metadata without logging credentials.

## Promotion policy

Bootstrap and dogfood `RunDiff Development` first. Create `RunDiff Staging` when we need a persistent pre-production environment. Create production `RunDiff` only after the development flow is green end-to-end and the production public URL and secret store are ready.
