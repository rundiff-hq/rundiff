# Implementation Plan 0002: Cloudflare-native Control Plane v1

## Goal

Prove the selected hosted Control Plane implementation without coupling the RunDiff domain to Cloudflare.

## Current status

Cloudflare platform spike: **Proven locally and remotely.**

Remaining acceptance gate: **real GitHub-originated same-PR BLOCK -> fix -> ALLOW**.

External blockers as of 2026-09-20:

- GitHub Actions run 35532900122 could not start because the account reports failed payments or an insufficient spending limit;
- production GitHub App credentials/proof scenario are not yet configured in the deployed Worker;
- an external demo repository/App installation is not yet configured.

Deployed proof endpoint:

~~~text
https://rundiff-control-plane.sergii-ponomarov.workers.dev
~~~

Worker version:

~~~text
ddd46bf8-43f9-4a1b-b9ec-a1437ac96f17
~~~

## Phase A - local lifecycle spike

Deliver:

- React + Vite UI;
- Hono Worker API;
- one D1 database;
- one Behavioral Review Workflow;
- create review endpoint;
- Workflow waits for external executor result;
- result endpoint sends Workflow event;
- final state persists to D1;
- Review Detail renders from D1.

Acceptance:

~~~text
POST create review
  -> D1 pending row
  -> Workflow running/waiting

POST fake executor result
  -> sendEvent(executor-result)
  -> Workflow resumes
  -> D1 completed/BLOCK or ALLOW

GET review
  -> exact durable state

React
  -> renders same review
~~~

## Phase B - port control-plane invariants

Port semantics, not Rails classes:

- GitHub delivery dedupe;
- exact repository/PR/base/head identity;
- current candidate authority;
- stale/superseded result rejection;
- execution attempt identity;
- finalization fence;
- GitHub publication state.

Every invariant needs a focused TypeScript test before live deployment.

## Phase C - GitHub bridge

Connect the existing GitHub Actions bridge design to the Worker:

~~~text
GHA
  -> claim exact Executor Request
  -> execute existing executor_service / later Go executor
  -> submit portable Executor Result
  -> Workflow event
~~~

Temporary scoped bearer auth is acceptable for the first bridge proof.

Target before public production use: GitHub Actions OIDC verification.

## Phase D - production resources

Create:

- Workers Paid project;
- D1 database;
- Workflow binding;
- R2 bucket;
- Worker secrets;
- GitHub App production secrets.

The authoritative production domain is confirmed as `rundiff.com`. Bind it only after the current landing experience is preserved at the apex; keep the verified `workers.dev` endpoint during the first cutover.

Budget guardrail: target <= USD 10/month; expected idle/low-volume platform cost near the Workers Paid base price.

## Phase E - external production proof

One external repository, one PR:

~~~text
opened
  -> deliberate SQL regression
  -> BLOCK

same PR synchronize
  -> fix
  -> ALLOW
~~~

Retain:

- Worker deployment version/SHA;
- D1 migration version;
- Workflow instance IDs;
- GitHub delivery IDs;
- installation/repository/PR identities;
- exact base and both candidate SHAs;
- execution/attempt IDs;
- Check/comment IDs;
- Finding fingerprint/evidence refs when PR #174 lands;
- actual Cloudflare/GitHub execution cost.

## Explicit stop

Do not add Durable Objects, Queues, Containers, Temporal, PostgreSQL, billing, RCA, or broader dashboard features before the above proof requires them.

See ADR 0016 and RFC 0011.
