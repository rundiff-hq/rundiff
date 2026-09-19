# RunDiff current state

This document is the canonical short-form snapshot of what is true **now**. It exists to prevent completed experiments, superseded proofs, deferred actions, and historical branding from being mistaken for the current product contract.

Architectural history still lives in ADRs, RFCs, closed issues, and archived demo PRs. Those records should remain intact when they explain why RunDiff works the way it does.

## Canonical product identity

```text
Product             RunDiff
GitHub organization rundiff-hq
Main repository     rundiff-hq/rundiff
Config              rundiff.yml
Environment prefix  RUNDIFF_
Control plane       https://app.rundiff.com
Executor            https://executor.rundiff.com
Production image    ghcr.io/rundiff-hq/rundiff
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

These are the actual current production blockers:

1. configure the production remote Terraform state/backend and real provider credentials;
2. perform the first guarded production infrastructure apply (#92);
3. deploy live control plane and executor;
4. complete the external GitHub App/Cloudflare identity cutover (#121);
5. install the public App from an account or organization outside `rundiff-hq`;
6. execute the GitHub-originated same-PR BLOCK -> fix -> ALLOW flow;
7. collect and retain Production Proof v2 (#75).

Until those are complete, RunDiff has a convincing product-shaped system and preproduction proof, but not the final external production proof.

## Explicitly superseded assumptions

The following statements are no longer current:

- the old pre-RunDiff brand/config/environment names are active;
- a workstation-hosted Development App/tunnel is a required production gate;
- production acceptance uses one regression PR plus a separate neutral PR;
- `bin/replay-github-pr` or `bin/prove-github-app-demo` can close external production acceptance;
- production proof v1 is the current evidence format;
- concrete production IaC still needs to be designed;
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
- non-Rails runtimes and broader customer setup policy.

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
