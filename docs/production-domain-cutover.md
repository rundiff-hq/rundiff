# Production domain cutover

Authoritative production identity:

~~~text
Product        RunDiff
Domain         https://rundiff.com
GitHub App     RunDiff Checks
App slug       rundiff-checks
Webhook        https://rundiff.com/api/github/webhooks
~~~

Current verified Worker fallback:

~~~text
https://rundiff-control-plane.sergii-ponomarov.workers.dev
~~~

Current landing reference before cutover:

~~~text
https://oaken-rapids-g7ze.here.now
~~~

## Target shape

~~~text
rundiff.com/
  -> public RunDiff landing

rundiff.com/dashboard
rundiff.com/reviews/...
  -> product UI

rundiff.com/api/*
  -> Hono Worker API

rundiff.com/api/github/webhooks
  -> signed GitHub App webhook receiver
~~~

The preferred end state is one Cloudflare Worker origin for the apex, with the landing and product UI shipped as Worker assets and the API handled by Hono.

Do not make the here.now deployment a permanent runtime dependency. A temporary proxy can be used only as an explicit short-lived cutover decision.

## Gate 1 - preserve the landing

Before binding the apex, promote the current landing design/source into `apps/control-plane-cloudflare` and make `/` render it.

The current Cloudflare React root is an internal Behavioral Review screen. Binding the apex before this gate would replace the public site with the wrong UI.

Expected before DNS/domain mutation:

~~~text
local /
  -> landing

local /api/health
  -> 200

local /api/ready
  -> 200

local review route
  -> product UI
~~~

## Gate 2 - production Wrangler config

Create the ignored local production config:

~~~bash
cd apps/control-plane-cloudflare
cp wrangler.production.jsonc.example wrangler.production.jsonc
~~~

Fill the real D1 database ID and any account-specific non-secret configuration.

The production template uses:

~~~json
{
  "workers_dev": true,
  "routes": [
    {
      "pattern": "rundiff.com",
      "custom_domain": true
    }
  ]
}
~~~

Keeping `workers_dev` enabled during the first cutover gives an immediate fallback URL.

Before deploy, inspect Cloudflare DNS for an existing record on the apex. Cloudflare Custom Domains cannot be attached to a hostname that conflicts with an existing CNAME/origin record. Do not delete or replace an existing apex record until its purpose is understood.

## Gate 3 - deploy and verify

After local tests/build and the landing gate are green:

~~~bash
npm run typecheck
npm test
npm run build
npx wrangler deploy --config wrangler.production.jsonc
~~~

Verify:

~~~text
https://rundiff.com/
https://rundiff.com/api/health
https://rundiff.com/api/ready
~~~

Expected API health:

~~~text
/api/health -> 200
/api/ready  -> 200
~~~

Also verify the old `workers.dev` endpoint still answers.

## Gate 4 - GitHub App cutover

In the existing organization GitHub App `RunDiff Checks`:

~~~text
Homepage URL:
https://rundiff.com

Webhook URL:
https://rundiff.com/api/github/webhooks

SSL verification:
enabled

Setup URL:
blank for now

Request user authorization during installation:
disabled

Device Flow:
disabled
~~~

Keep the current webhook secret. Do not rotate it merely for the hostname change.

Redeliver one recent safe `pull_request` delivery and require an accepted response from the production Worker before treating the GitHub cutover as complete.

## Gate 5 - proof and rollback

Run the normal same-PR production proof:

~~~text
opened
  -> BLOCK

same PR + fix + synchronize
  -> ALLOW
~~~

If the apex cutover fails, remove/revert only the new Custom Domain binding and continue using the verified `workers.dev` endpoint while fixing the root cause. Do not rotate GitHub App credentials as part of a domain rollback.

After a stable production period, `workers_dev` may be disabled deliberately in a separate change.
