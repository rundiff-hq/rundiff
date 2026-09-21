# RunDiff current state

This document is the canonical short-form snapshot of what is true **now**. It exists to prevent completed experiments, superseded proofs, deferred actions, and historical branding from being mistaken for the current product contract.

Architectural history still lives in ADRs, RFCs, closed issues, and archived demo PRs. Those records should remain intact when they explain why RunDiff works the way it does.

## Canonical product identity

```text
Product             RunDiff
GitHub organization rundiff-hq
Main repository     rundiff-hq/rundiff
GitHub App          RunDiff Checks (slug: rundiff-checks)
Config              rundiff.yml
Environment prefix  RUNDIFF_
Production URL      https://rundiff.com
Production webhook  https://rundiff.com/api/github/webhooks
Control plane       implementation-independent; Cloudflare-native selected for production v1
Hosted endpoint     https://rundiff.com live on Cloudflare Worker Custom Domain
Fallback endpoint   https://rundiff-control-plane.sergii-ponomarov.workers.dev
Landing source      committed into Cloudflare app root from the generated landing artifact
Landing reference   https://oaken-rapids-g7ze.here.now (design/source reference)
Executor             GitHub Actions first; managed providers later
Rails image          ghcr.io/rundiff-hq/rundiff (reference/fallback implementation)
```

Pre-RunDiff product names and configuration names are historical only. They must not appear in active operator/customer instructions.

## Current customer contract

The narrow v0.1 customer path is:

```text
/open onboarding
  -> install public RunDiff GitHub App
  -> select external Rails repository
  -> add candidate-only rundiff.yml
  -> open PR
  -> exact baseline/candidate execution
  -> RunDiff / Behavioral Review
```

For the first production proof, the repository requires no RunDiff gem, GitHub Action, middleware, initializer, Docker configuration, executor configuration, or repository runtime file beyond `rundiff.yml`.

The currently proven subject scope is Rails with PostgreSQL or SQLite. Broader setup/runtime support remains future work.

## Durable data model

The current Rails schema uses only canonical RunDiff naming:

```text
github_webhook_deliveries
rundiff_evidence_events
rundiff_execution_work_items
rundiff_executions
rundiff_executor_requests
```

There is no remaining pre-RunDiff table naming debt in the committed schema.

Production Proof v1 is retained only as a historical versioned schema and is explicitly deprecated. New external acceptance must use Production Proof v2.

## What is already proven

The following are implementation facts, not future assumptions:

- exact baseline/candidate Git worktrees;
- candidate-owned `rundiff.yml` applied as the shared comparison scenario;
- isolated Rails + PostgreSQL and Rails + SQLite subject state;
- deterministic Behavioral Diff and Behavioral Review rendering;
- SQL regression detection including `DATABASE_QUERY_REGRESSION`;
- durable GitHub execution lifecycle, leases, stale guards, cancellation and finalization fencing;
- remote executor Request v1 / Result v1 boundary;
- repository-scoped short-lived clone capability kept out of durable executor payloads;
- executor deployment isolation without GitHub App private key/webhook secret;
- separate-process `git_clone` execution path in `remote_executor_topology`;
- GitHub Check plus one durable updateable PR comment;
- hermetic Production Lab using Vercel Labs `emulate` for App authentication/installations/webhook delivery;
- emulator-originated PR event -> signed webhook -> control plane -> remote executor -> Check/comment;
- same-org installed-App replay/preflight tooling for operator diagnostics;
- public production manifest and hosted onboarding surface;
- production image/release/deployment contracts;
- Terraform/Cloudflare/Hetzner infrastructure contract in `rundiff-hq/infra`;
- production identity, Cloudflare and topology verifiers;
- Production Proof v2 collector.
- Cloudflare Worker + D1 + Workflow + R2 remote spike deployment;
- remote portable bridge BLOCK and ALLOW lifecycles with durable D1 state;
- local duplicate/conflicting Result, timeout, executor-failure, stale candidate,
  supersede, and finalization-fence verification;
- production same-repository GitHub `pull_request/synchronize` -> Cloudflare -> GitHub Actions bridge -> Ruby reference executor -> Result v1 -> `RunDiff Checks` ALLOW proof on 2026-09-21, candidate `2911af4d730e019e917e1addc00bae87c4545b02`, execution `39c54ef3-1f76-45ce-92dd-ccc260311418`;
- production privacy boundary verified: `/` intentionally returns 404 while `/api/health` and `/api/ready` return 200 and unauthenticated review reads return 401.

## Production Proof v2

Canonical external acceptance uses **one PR**, not separate regression and neutral PRs:

```text
PR opened with deliberate SQL regression
  -> real GitHub pull_request/opened
  -> BLOCK

push behavioral fix to the same PR
  -> real GitHub pull_request/synchronize
  -> ALLOW
```

The final evidence collector requires:

- same repository, PR, branch, baseline and GitHub App installation;
- different BLOCK and ALLOW candidate SHAs;
- `opened` for BLOCK and `synchronize` for ALLOW;
- exact durable execution identity for each revision;
- immutable Check Run tied to each exact candidate SHA;
- final current PR head equal to the ALLOW candidate;
- both `X-GitHub-Delivery` GUIDs present in authenticated GitHub App webhook delivery history;
- one durable PR comment, currently updated to ALLOW.

Operator replay, curl, or another locally synthesized webhook cannot satisfy this production proof.

## What is not proven live yet

The internal production transport path is now proven. The remaining canonical external acceptance work is narrower:

1. install the public `RunDiff Checks` App on a repository/account outside `rundiff-hq`;
2. execute the real GitHub-originated same-PR BLOCK -> behavioral fix -> ALLOW sequence there;
3. collect and retain Production Proof v2 with both authenticated GitHub delivery GUIDs and exact Check Run identities;
4. record actual monthly production cost after representative low-volume use.

The same-repository production ALLOW proof validates the Cloudflare/GitHub Actions/Ruby reference transport, but it does not replace the required external-account BLOCK -> ALLOW acceptance proof.

## Executor protocol v1 freeze

The executor transport contract is frozen before the managed Go implementation. Canonical schemas and golden fixtures live under `protocol/executor/v1` and are consumed by both Ruby and TypeScript contract tests.

Request/Result v1 is executor-portable but still contains optional GitHub-oriented compatibility context. Provider credentials and delivery identity stay outside the protocol. The current GitHub Actions tuple-based claim is a bridge-specific bootstrap; managed executors must be assigned by exact `execution_id + attempt_number`.

Cloudflare's current bridge lifecycle is sufficient for the proven GitHub Actions transport, but managed Go execution still requires durable attempt leases, heartbeat/progress, cancellation, expiry, and finalization fencing before that path becomes the canonical managed lifecycle.

## Explicitly superseded assumptions

The following statements are no longer current:

- the old pre-RunDiff brand/config/environment names are active;
- a workstation-hosted Development App/tunnel is a required production gate;
- production acceptance uses one regression PR plus a separate neutral PR;
- `bin/replay-github-pr` or `bin/prove-github-app-demo` can close external production acceptance;
- production proof v1 is the current evidence format;
- the first production proof requires a permanent VM/PostgreSQL/Solid Queue topology;
- executor deployment isolation still needs proof;
- a separate-process control-plane -> executor-service `git_clone` path still needs proof.

Historical documents may still mention those facts in the context of the work that originally proved or motivated them. They should be labeled as history rather than reused as current instructions.

## Deliberately retained architecture/future work

Do not remove these simply because they are not part of the immediate #75 path:

- ADRs and RFCs that explain architecture choices;
- old exact-run demo evidence retained in closed PRs;
- managed executor/provider abstraction work (#76-#84, #87);
- SQL semantics/cardinality work (#95);
- Subject Setup Plan (#100);
- noisy timing repeated-sampling hardening (#103/#137);
- remote-topology CI seed optimization (#138);
- successful Production Lab timing summary (#140);
- worker-host heartbeat/hard termination;
- fork-PR multi-repository capability model;
- non-Rails runtimes and broader customer setup policy;
- composable Execution Plan / managed placement / Review Credit model from RFC 0004;
- repository-owned /rundiff.yml, Review Workload discovery/selection, and source-code boundary from RFC 0007;
- ownership-aware finding routing through CODEOWNERS and external delivery adapters from RFC 0008.
- managed Go Executor host runtime, resource journal/sweeper cleanup, local evidence bus, and controlled-host isolation from RFC 0009.
- behavioral Rule/Finding/Diagnosis/Relation taxonomy and investigation model from RFC 0010.
- implementation-independent Control Plane with Cloudflare-native production v1 from ADR 0016 / RFC 0011.

These are real future capabilities or architectural records, not blockers for the first external product proof unless an issue explicitly says otherwise.

## Historical demo policy

Old intentional demo PRs are valuable evidence but should not remain in the active PR queue indefinitely.

The pre-RunDiff async demo PRs #13, #21, #24, #28 and #30 are archived/closed with their original run IDs, SHAs, measurements and historical check names preserved.

PR #149 remains the current live RunDiff SQL-regression demo and is intentionally not mergeable product work.

## Source-of-truth order

When records disagree, use this order:

1. executable code/schemas and green CI;
2. `docs/current-state.md`;
3. current production/operator runbooks;
4. open acceptance issues (#75/#92/#121 for the production cutover);
5. architecture docs / accepted ADRs and RFC decisions;
6. closed issues and archived demo PRs as historical evidence.

A future vertical slice that changes one of these contracts should update this snapshot in the same change or explicitly explain why it does not.
