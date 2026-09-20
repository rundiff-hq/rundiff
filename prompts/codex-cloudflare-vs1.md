# Codex prompt: finish RunDiff Cloudflare production VS1

You are working in the `rundiff-hq/rundiff` repository on branch `feat/cloudflare-control-plane-v1`.

Your job is to carry the Cloudflare-native RunDiff Control Plane from the current scaffold to the strongest safely verifiable production proof possible from this machine.

Read and follow:

- `apps/control-plane-cloudflare/AGENTS.md`
- `docs/rfcs/0011-portable-control-plane-cloudflare-v1.md`
- `docs/implementation-plans/0002-cloudflare-control-plane-v1.md`
- `docs/architecture.md`
- `docs/current-state.md`
- `apps/control-plane-cloudflare/README.md`

Also inspect GitHub PR #173 / branch `feat/github-actions-execution-bridge` as a semantic reference for the Rails implementation of the GitHub Actions bridge. Preserve its useful invariants, but do not port Rails classes line by line.

## First: inspect, do not mutate

1. Check git status and current branch.
2. Inspect current PR #175 diff.
3. Run:
   - npm install if necessary
   - npm run typecheck
   - npm run build
   - local D1 migrations
4. Inspect Cloudflare account state using read-only Wrangler and/or Cloudflare MCP:
   - authenticated account(s);
   - existing Worker named `rundiff-control-plane`;
   - existing D1 named `rundiff-control-plane`;
   - existing R2 bucket named `rundiff-artifacts`;
   - existing Workflow named `rundiff-behavioral-review`.
5. Report what already exists before creating anything.

Do not print authentication tokens or private keys.

## Then: fix the local spike until it is real

Make the current Cloudflare application actually pass:

- TypeScript typecheck;
- Vite/Worker build;
- local D1 migrations;
- local Worker startup;
- Behavioral Review creation;
- Workflow transitions to waiting-for-executor;
- GitHub Actions bridge claim returns exact portable Executor Request v1;
- portable Executor Result v1 submission;
- identical result retry is idempotent;
- conflicting result retry is rejected;
- Workflow resumes and persists ALLOW/REVIEW/BLOCK;
- executor failure maps to INFRA_FAILURE;
- timeout/lifecycle failure maps to INFRA_FAILURE;
- React Review Detail reads durable state.

Add focused automated tests where they materially reduce risk.

Never claim a path works unless you actually ran it.

## Port production safety invariants

Implement the minimum production GitHub path needed for VS1:

1. signed GitHub App webhook verification;
2. X-GitHub-Delivery deduplication;
3. pull_request opened/synchronize/reopened handling;
4. exact repository + PR + installation + base SHA + candidate SHA persistence;
5. one authoritative current candidate per PR;
6. superseded/stale execution cannot finalize as current;
7. finalization fence / compare-and-set semantics;
8. result bound to exact execution and attempt;
9. before GitHub publication, verify the PR's current head still matches the candidate;
10. publish a GitHub Check and one updateable PR comment tied to the exact candidate SHA.

Use the existing Rails implementation as a semantic oracle.

Keep GitHub identity/auth separate from repository installation semantics.

Do not persist customer source code.

## GitHub Actions bridge

Keep the existing portable Request/Result v1 contract.

Temporary scoped bearer auth is acceptable for the first end-to-end proof if it is already the shortest path.

If practical without delaying the proof, replace it with GitHub Actions OIDC:
- verify issuer;
- verify audience;
- verify repository/workflow/ref claims appropriate for the execution;
- keep repository token read-only and inside the runner.

Do not expand GitHub App permissions merely to authenticate the executor.

## Cloudflare resource provisioning

Once local verification is green, provision/update only the RunDiff-scoped resources needed for VS1.

Reserved names:

- Worker: `rundiff-control-plane`
- D1: `rundiff-control-plane`
- R2: `rundiff-artifacts`
- Workflow: `rundiff-behavioral-review`

Rules:

- inspect before create;
- avoid duplicates;
- prefer idempotent updates;
- keep expected platform cost <= USD 10/month;
- do not change account plan/billing;
- do not delete unrelated resources;
- do not touch DNS/WAF/Zero Trust/Tunnels/Email Routing;
- do not bind a custom domain yet;
- do not expose secret values in logs;
- do not commit secret material.

The authoritative production domain is unresolved. Historical repo docs say `rundiff.com`; prior planning also mentioned `rundiv.com`. Stop before any DNS/custom-domain mutation and ask the user to confirm the authoritative domain.

Create a real local `wrangler.jsonc` if required, but keep account-specific/generated local config uncommitted unless it is intentionally sanitized and portable.

Use Wrangler and Cloudflare MCP according to their strengths:
- Wrangler: local dev, migrations, deploy, product-specific CLI commands;
- Cloudflare MCP: account/resource inspection and Cloudflare API operations;
- Cloudflare docs/skills: current platform guidance.

## Remote verification

After provisioning:

1. apply remote D1 migrations;
2. deploy the Worker;
3. verify /api/health and /api/ready;
4. create a non-GitHub spike review remotely;
5. claim it;
6. submit a portable BLOCK Result;
7. verify durable D1 state and React/API display;
8. repeat with ALLOW;
9. inspect Worker/Workflow logs for errors;
10. record exact deployed Worker version/resource IDs but never credentials.

## Real GitHub production proof

If GitHub App credentials and an external demo repository are already safely available on this machine, continue to:

~~~text
real pull_request/opened
 -> Worker webhook
 -> durable Review/Execution
 -> GitHub Actions claim
 -> existing executor_service
 -> portable Result
 -> BLOCK

same PR push fix
 -> pull_request/synchronize
 -> old candidate cannot publish
 -> new execution
 -> ALLOW
~~~

No synthetic webhook/curl result may count as the final external acceptance proof.

If required GitHub App credentials or external repo setup are missing, stop at the exact boundary and give the user the shortest safe action required.

## Explicit non-goals

Do not add:

- Durable Objects;
- Queues;
- Cloudflare Containers executor;
- Temporal;
- PostgreSQL;
- Rails rewrite/deletion;
- Performance/Deep evidence;
- billing implementation;
- causal graph/RCA;
- broad admin dashboard.

Do not expand scope because a Cloudflare product looks interesting.

## Repository hygiene

- make small coherent commits;
- keep code comments in English;
- update documentation when behavior changes;
- keep PR #175 description/status accurate;
- preserve Rails as reference/fallback;
- do not merge #175 until actual verification is green;
- do not silently skip failing tests.

## Final report

At the end give me:

1. exact git commits made;
2. commands/checks run and their results;
3. Cloudflare resources created/updated, with IDs/names but no secrets;
4. current deployed URL if any;
5. what is proven locally;
6. what is proven remotely;
7. what remains before real BLOCK -> fix -> ALLOW;
8. actual/estimated monthly cost;
9. any architecture deviation from ADR 0016/RFC 0011 and why.
