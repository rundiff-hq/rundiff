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

Status: **implemented and deployed to the production Worker; browser/API verification still required from a client**.

The generated landing artifact is committed as `apps/control-plane-cloudflare/src/react-app/landing.html` and rendered at `/`. The prior Behavioral Review UI remains on non-root SPA routes such as `/dashboard`.

Before binding the apex, verify that the landing matches the intended public site and that the review route still works.

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

The sanitized production template already contains the existing production D1 database ID. Review account/profile selection and do not add secrets to the file.

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

After local tests and the landing gate are green, build **through the Cloudflare Vite plugin using the production Wrangler input config**, then deploy the generated output config:

~~~bash
npm run typecheck
npm test
npm run build:production
npx wrangler deploy --config dist/rundiff_control_plane/wrangler.json
~~~

Do not deploy the input `wrangler.production.jsonc` directly. With the Cloudflare Vite plugin, that file is an input configuration; `vite build` writes the deployable snapshot to `dist/rundiff_control_plane/wrangler.json` and injects the generated client assets directory there.

Equivalent one-command production deploy:

~~~bash
npm run deploy:production
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


## Deployment record

Production Custom Domain deployment completed successfully on 2026-09-21.

~~~text
Worker       rundiff-control-plane
Custom domain https://rundiff.com
Fallback      https://rundiff-control-plane.sergii-ponomarov.workers.dev
Workflow      rundiff-behavioral-review
Version ID    6491ac44-93c4-418f-9c9d-c1323d7edf26
~~~

The final deploy uploaded the current landing asset bundle after the public GitHub App CTA/private-repository-link cleanup. Remaining checks are client-visible root/API verification and GitHub webhook redelivery.
