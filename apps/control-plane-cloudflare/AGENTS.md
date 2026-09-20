# RunDiff Cloudflare Control Plane - agent instructions

## Mission

Finish the first production proof of the Cloudflare-native RunDiff Control Plane without coupling RunDiff domain semantics to Cloudflare.

Read first:

1. ../../docs/rfcs/0011-portable-control-plane-cloudflare-v1.md
2. ../../docs/implementation-plans/0002-cloudflare-control-plane-v1.md
3. ../../docs/architecture.md
4. ../../docs/current-state.md
5. README.md

Reference implementation for execution-bridge semantics:

- GitHub PR #173 / branch feat/github-actions-execution-bridge
- existing Rails GitHub App lifecycle code under app/, lib/rundiff/github/, lib/rundiff/execution/

Do not port Rails classes line by line. Preserve invariants and portable contracts.

## Architectural boundary

Control Plane is a domain authority, not a Worker/D1/Workflow product.

Cloudflare v1 adapters:

- Hono Worker API
- D1 persistence
- Cloudflare Workflows lifecycle
- R2 artifacts
- GitHub Actions first execution orchestrator

Future alternatives may include Rails/PostgreSQL/Temporal or other runtimes.

Do not leak Cloudflare types into domain modules.

## VS1 scope

Target flow:

~~~text
real GitHub pull_request/opened
  -> signed Worker webhook
  -> delivery dedupe
  -> exact repository/PR/base/head identity
  -> D1 Behavioral Review + Execution
  -> Workflow
  -> GitHub Actions claims Executor Request v1
  -> existing executor runs BASE/candidate
  -> Executor Result v1
  -> idempotency/finalization fence
  -> re-check current PR head
  -> GitHub Check/comment
  -> BLOCK

same PR synchronize after fix
  -> supersede prior candidate
  -> new exact execution
  -> ALLOW
~~~

## Required safety invariants

- exact baseline/candidate SHA identity;
- GitHub delivery deduplication;
- one authoritative current candidate per PR;
- stale/superseded execution cannot publish as current;
- exact execution + attempt identity;
- identical Result retries are idempotent;
- conflicting Result retries are rejected;
- only one finalization wins;
- executor timeout becomes INFRA_FAILURE;
- GitHub publication is tied to exact candidate SHA;
- customer source is never persisted by the Control Plane;
- GitHub App private key/webhook secret never reach the executor.

## Portable protocol

Do not redefine:

- Executor Request v1
- Executor Result v1

Use existing schemas/Ruby implementation as the compatibility oracle.

## Cloudflare account safety

You may create/update only RunDiff-scoped resources required for this proof:

- Worker: rundiff-control-plane
- D1: rundiff-control-plane
- R2 bucket: rundiff-artifacts
- Workflow: rundiff-behavioral-review
- Worker secrets required by the RunDiff proof

Before every remote mutation:

1. inspect existing resource state;
2. avoid duplicate resources;
3. prefer idempotent/update behavior;
4. state what will change.

Do NOT:

- change account billing/subscription;
- delete unrelated Cloudflare resources;
- alter WAF, Zero Trust, DNS, tunnels, email routing, or zones;
- bind a production custom domain;
- mutate DNS until the user explicitly confirms the authoritative RunDiff domain;
- expose or print credentials/tokens/private keys;
- commit wrangler.jsonc containing account-specific secrets;
- commit .dev.vars or secret material.

Budget guardrail for VS1: <= USD 10/month expected platform cost.

## Authentication

Prefer local Wrangler OAuth/profile for interactive development.

Prefer Cloudflare MCP OAuth for platform inspection/API operations.

Never copy Cloudflare access tokens into source files or prompts.

## Verification before remote deploy

At minimum:

~~~text
npm install
npm run typecheck
npm run build
local D1 migrations
local Workflow create -> wait -> result -> final state
bridge claim
portable Result submission
duplicate Result retry
conflicting Result rejection
timeout/INFRA_FAILURE path where practical
~~~

Do not claim a path is verified unless it actually ran.

## Stop line

Do not add these before VS1 requires them:

- Durable Objects
- Queues
- Containers executor
- Temporal
- PostgreSQL
- broad billing system
- causal graph/RCA expansion
- full organization/admin dashboard

## Working style

- make small commits;
- keep code comments in English;
- update docs when behavior changes;
- preserve Rails implementation as reference/fallback;
- prefer explicit tests over prose assertions;
- never hide a failed check.
