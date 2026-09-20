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

5. Run the focused invariant suite:

~~~bash
npm test
~~~

## Spike flow

Create:

~~~bash
curl -sS -X POST http://localhost:5173/api/spike/reviews \
  -H 'content-type: application/json' \
  -d '{
    "repository":"demo/shop",
    "pull_request_number":42,
    "scenario_id":"orders.show",
    "baseline_sha":"aaaaaaaa",
    "candidate_sha":"bbbbbbbb",
    "baseline_ref":"main",
    "candidate_ref":"pull/42/head"
  }'
~~~

The response contains the review ID and the exact portable Executor Request. The Workflow moves the review to `waiting_for_executor`.

For the bridge flow, configure a local secret:

~~~bash
npx wrangler secret put RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN
~~~

Claim the exact Request:

~~~bash
curl -sS -X POST http://localhost:5173/api/execution-bridges/github-actions/claim \
  -H 'authorization: Bearer <TOKEN>' \
  -H 'content-type: application/json' \
  -d '{
    "repository":"demo/shop",
    "pull_request_number":42,
    "baseline_sha":"aaaaaaaa",
    "candidate_sha":"bbbbbbbb"
  }'
~~~

Submit a portable Executor Result v1:

~~~bash
curl -sS -X POST \
  http://localhost:5173/api/executions/<EXECUTION_ID>/attempts/1/result \
  -H 'authorization: Bearer <TOKEN>' \
  -H 'content-type: application/json' \
  -d '{
    "schema_version":"1",
    "status":"succeeded",
    "payload":{
      "result":{
        "merge_recommendation":"block",
        "findings":[
          {
            "reason_code":"DATABASE_QUERY_REGRESSION",
            "signal":"sql_queries",
            "baseline":17,
            "candidate":31
          }
        ]
      }
    },
    "error_class":null,
    "error_message":null
  }'
~~~

The result endpoint records a canonical SHA-256 digest for idempotency, then delivers `executor-result` to the Workflow. Identical retries are accepted; conflicting result content is rejected.

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

`RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN` is the temporary bridge credential for this proof.

Target before public customer use: GitHub Actions OIDC.

The production GitHub webhook path also requires these Worker secrets/variables:

~~~text
RUNDIFF_GITHUB_APP_ID
RUNDIFF_GITHUB_APP_PRIVATE_KEY
RUNDIFF_GITHUB_WEBHOOK_SECRET
RUNDIFF_GITHUB_SCENARIO_ID
~~~

It verifies `X-Hub-Signature-256`, deduplicates `X-GitHub-Delivery`, accepts
`pull_request` opened/synchronize/reopened events, and fences claim, result,
finalization, Check publication, and PR comment publication against the exact
current candidate SHA. VS1 currently accepts same-repository pull requests.

Never commit GitHub App private keys, webhook secrets, API tokens, or real Wrangler secret values.

## Production

Do not bind a custom domain until the authoritative RunDiff production domain is explicitly verified.

The verified spike deployment uses the default Workers hostname:

~~~text
https://rundiff-control-plane.sergii-ponomarov.workers.dev
~~~

See:
- ADR 0016
- RFC 0011
- docs/implementation-plans/0002-cloudflare-control-plane-v1.md
