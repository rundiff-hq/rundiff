# VS18 - Automatic External Executor Dispatch v1

Status: implementation slice

## Goal

Remove the proof-only manual runner from the customer path.

Target lifecycle:

```text
customer pull request
-> RunDiff GitHub App webhook
-> Cloudflare control plane
-> exact execution persisted
-> Cloudflare Workflow
-> central GitHub Actions executor dispatch
-> exact claim + lease
-> Go managed executor
-> Result v1
-> GitHub Check + PR comment
```

No customer repository needs to install a RunDiff workflow file.

## Capability separation

Two different GitHub App installation capabilities are used.

### Customer repository capability

Minted from the installation id carried by the customer webhook.

Purpose:

- verify the current PR candidate;
- clone the exact customer repository revision;
- publish the RunDiff Check/comment.

This token is repository scoped and is delivered to the Go executor only after an exact attempt is claimed.

### Platform dispatch capability

Minted independently for the RunDiff platform repository:

```text
rundiff-hq/rundiff
```

The Worker discovers the GitHub App installation for that repository, then mints a short-lived token restricted to that repository with:

```text
Actions: write
```

It is used only to create a `workflow_dispatch` event for the central executor workflow.

Customer installations are never used to control RunDiff's platform repository.

## Dispatch contract

Workflow:

```text
.github/workflows/rundiff-executor-dispatch.yml
```

Inputs:

```text
execution_id
attempt_number
repository
candidate_sha
```

Only `execution_id + attempt_number` are authoritative for execution. Repository and candidate SHA are audit/context values.

The runner calls:

```text
rundiff-executor agent
  --execution-id <exact id>
  --attempt <exact attempt>
```

The control plane then supplies Request v1 and a short-lived customer repository capability through the exact-claim endpoint.

## At-least-once dispatch and duplicate safety

GitHub dispatch is treated as an at-least-once side effect.

A retry can theoretically create more than one workflow run. Correctness is protected by the existing exact-attempt claim:

```text
available -> claimed
```

Only one runner can claim the attempt.

Additional dispatched runners receive HTTP 409 from exact claim. The central runner uses:

```text
--unclaimable-ok
```

and exits successfully without executing customer code.

Therefore duplicate dispatch can waste a small runner startup, but cannot duplicate the behavioral execution or submit a second competing result.

## Durable orchestration

Dispatch happens inside the Cloudflare BehavioralReviewWorkflow, after the review is marked waiting and before waiting for Result v1.

The workflow remains responsible for:

```text
mark waiting
-> dispatch exact executor
-> wait for executor result
-> finalize durable decision
-> publish GitHub review
```

## Rollout gate

Automatic dispatch is disabled unless:

```text
RUNDIFF_EXECUTOR_AUTODISPATCH=github_actions
```

This allows the code and workflow to land before production cutover.

Before enabling:

1. the dispatch-enabled workflow must exist on the default branch;
2. the RunDiff GitHub App must have `Actions: write` permission on the platform installation;
3. the Cloudflare Worker containing VS18 must be deployed;
4. one external PR synchronize event must prove automatic BLOCK/ALLOW or ALLOW+WARNING without the proof workflow.

## Cutover acceptance

Use `rundiff-hq/example-node-express-postgres#1`.

Acceptance is complete only when a fresh external PR synchronize event produces a RunDiff execution with **no push/manual proof trigger** and the GitHub review is published automatically.

After that proof:

- remove `.github/workflows/external-node-proof.yml`;
- remove `docs/proofs/external-node-proof.json`;
- keep the public external fixture PR as the long-lived acceptance/demo target.
