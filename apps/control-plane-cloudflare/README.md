# RunDiff Cloudflare Control Plane

First hosted production implementation of the implementation-independent RunDiff Control Plane.

## Stack

- React + Vite
- Hono Worker API
- D1
- Cloudflare Workflows
- R2 (bound now; artifact usage follows after lifecycle spike)

The Rails application remains the reference/fallback implementation.

## Local spike

1. Install:

~~~bash
npm install
~~~

2. Create a local Wrangler config:

~~~bash
cp wrangler.jsonc.example wrangler.jsonc
~~~

For local-only work, use a temporary UUID in the D1 `database_id` field. Before remote deployment, replace it with the real ID returned by:

~~~bash
npx wrangler d1 create rundiff-control-plane
~~~

Create the R2 bucket before remote deployment:

~~~bash
npx wrangler r2 bucket create rundiff-artifacts
~~~

3. Apply D1 migrations:

~~~bash
npx wrangler d1 migrations apply rundiff-control-plane --local
~~~

4. Run:

~~~bash
npm run dev
~~~

## Spike flow

Create:

~~~bash
curl -sS -X POST http://localhost:5173/api/spike/reviews \
  -H 'content-type: application/json' \
  -d '{
    "project_id":"demo/shop",
    "scenario_id":"orders.show",
    "baseline_sha":"aaaaaaaa",
    "candidate_sha":"bbbbbbbb"
  }'
~~~

The response contains the review ID. The Workflow moves it to `waiting_for_executor`.

Deliver a fake executor result:

~~~bash
curl -sS -X POST http://localhost:5173/api/spike/reviews/<REVIEW_ID>/result \
  -H 'content-type: application/json' \
  -d '{
    "decision":"BLOCK",
    "result":{
      "rule_id":"database.query.count.regression",
      "baseline":17,
      "candidate":31
    }
  }'
~~~

Read:

~~~bash
curl -sS http://localhost:5173/api/reviews/<REVIEW_ID>
~~~

Expected lifecycle:

~~~text
starting
 -> waiting_for_executor
 -> completed/BLOCK
~~~

If no result arrives within 30 minutes:

~~~text
waiting_for_executor
 -> infra_failure/INFRA_FAILURE
~~~

## Security

`RUNDIFF_SPIKE_TOKEN` is optional only for local spike convenience.

Before public result submission, use explicit bridge authentication. Target: GitHub Actions OIDC.

Never commit GitHub App private keys, webhook secrets, API tokens, or real Wrangler secret values.

## Production

Do not bind a custom domain until the authoritative RunDiff production domain is explicitly verified.

See:
- ADR 0016
- RFC 0011
- docs/implementation-plans/0002-cloudflare-control-plane-v1.md
