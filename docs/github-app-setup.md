# GitHub App setup

RunDiff uses separate GitHub App identities by environment.

- Development: `RunDiff Development`
- Staging: `RunDiff Staging`
- Production: **`RunDiff Checks`**
- Production App slug: **`rundiff-checks`**
- Owner: **`rundiff-hq`**

The production App already exists. Do not create a second production App from the manifest launcher.

## Production identity

Canonical production settings:

~~~text
App name       RunDiff Checks
Homepage       https://rundiff.com
Webhook        https://rundiff.com/api/github/webhooks
Setup URL      blank until hosted onboarding is implemented
OAuth on install disabled
Device Flow    disabled
~~~

The production `.github/app-manifest.json` is kept as a declarative settings snapshot for the existing App. It is not the creation path for a second production App.

The Cloudflare-native production webhook path is:

~~~text
POST /api/github/webhooks
~~~

The Rails reference/fallback implementation still has its historical `POST /github/webhooks` route. Do not use that path for the Cloudflare production App.

## Development and staging bootstrap

The Rails bootstrap launcher remains useful for Development and Staging:

~~~bash
bash bin/setup-github-app development
bash bin/setup-github-app staging
~~~

Those manifests use `{{RUNDIFF_PUBLIC_URL}}` and the Rails manifest callback flow. Development may use a Quick Tunnel. Staging should use a stable public URL.

Do not run the production launcher to replace or duplicate the existing `RunDiff Checks` App.

## Permissions and events

The current App contract is:

~~~text
Checks        read/write
Contents      read
Pull requests read/write
~~~

Subscribed events:

~~~text
pull_request
check_run
~~~

GitHub installation lifecycle deliveries are sent independently of the explicit event list.

## Webhook security

The production Worker requires a valid `X-Hub-Signature-256` generated with `RUNDIFF_GITHUB_WEBHOOK_SECRET`.

Production Worker secrets/variables:

~~~text
RUNDIFF_GITHUB_APP_ID
RUNDIFF_GITHUB_APP_PRIVATE_KEY
RUNDIFF_GITHUB_WEBHOOK_SECRET
RUNDIFF_GITHUB_SCENARIO_ID
~~~

Never commit their values.

## Repository-content permission policy

Keep repository contents read-only for the normal RunDiff App.

Do not expand to Contents write merely to create or update `/rundiff.yml`. Configuration onboarding should use a user-confirmed GitHub browser handoff:

~~~text
RunDiff control panel
  -> generate configuration
  -> open GitHub browser UI
  -> user commits on a branch
  -> user opens PR
~~~

Checks and pull-request presentation permissions are separate and may remain writable where required by RunDiff review surfaces.

## User authentication versus App installation

Treat user authentication and App installation as separate steps:

~~~text
Sign in with GitHub
  -> establishes RunDiff user identity/session

Install RunDiff Checks GitHub App
  -> grants repository-scoped RunDiff access
~~~

Do not use broad OAuth repository write scope as a shortcut for repository configuration.
