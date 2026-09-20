# Implementation Plan: GitHub Actions execution bridge

## Status

Draft vertical slice on branch `feat/github-actions-execution-bridge`.

## Goal

Prove an external orchestrator Execution Plan without rewriting the existing executor.

For this slice:

~~~text
orchestrator     GitHub Actions
compute          GitHub-hosted runner
runner backend   GitHub-hosted
runtime          existing RunDiff executor_service container
evidence         Standard
control plane    authoritative Rails control plane
~~~

## Core rule

GitHub Actions does not decide the behavioral result or construct an independent RunDiff domain model.

The control plane creates and owns the durable execution attempt.

The Action receives the exact portable `RunDiff::Executor::Request`, runs the existing executor service locally on the GitHub runner, and returns the portable `RunDiff::Executor::Result`.

## Flow

~~~text
GitHub pull_request
      |
      +---------------------------+
      |                           |
      v                           v
RunDiff GitHub App webhook    GitHub Actions workflow
      |                           |
      v                           | polls/claims
Control Plane                    |
      |                           |
create durable execution          |
claim + lease                      |
      |                           |
      +------ portable Request --->+
                                  |
                                  v
                         local executor_service
                         on GitHub runner
                                  |
                          short-lived GITHUB_TOKEN
                          contents: read only
                                  |
                                  v
                         clone BASE + candidate
                         run selected workload
                         produce Result
                                  |
      +<--------- portable Result--+
      |
      v
existing finalizer
      |
      +--> stale/finalization fence
      +--> Behavioral Diff publication
      +--> GitHub Check/comment
~~~

## Why pull/claim instead of workflow_dispatch in v1

The customer workflow already receives the pull_request event.

Using a pull/claim bridge means the RunDiff GitHub App does not need Actions: write merely to start the proof.

The workflow can retry the claim briefly until the signed RunDiff App webhook has created and claimed the matching durable execution.

Later, RunDiff may add an Actions-write dispatch strategy or another external orchestrator bridge without changing Request/Result.

## Control-plane change

Introduce `RUNDIFF_EXECUTION_ORCHESTRATOR`:

~~~text
native          existing RunDiffExecutorJob path
github_actions  leave the claimed execution available to the external bridge
~~~

Default remains `native`.

No existing production default changes.

## Bridge API

PoC authentication uses one explicit bearer secret:

~~~text
RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN
~~~

This is intentionally temporary. A production-quality external bridge should move to GitHub OIDC or another short-lived identity proof.

### Claim

~~~text
POST /v1/execution-bridges/github-actions/claim
Authorization: Bearer <bridge-token>

{
  "repository": "owner/repo",
  "pull_request_number": 42,
  "baseline_sha": "...",
  "candidate_sha": "..."
}
~~~

Response:

~~~json
{
  "request": {
    "schema_version": "1",
    "execution_id": "...",
    "scenario_id": "...",
    "baseline_sha": "...",
    "candidate_sha": "...",
    "attempt_number": 1,
    "context": {}
  }
}
~~~

Claim is read-like/idempotent. It does not create another execution attempt.

If the control plane has not created/claimed the exact attempt yet, return conflict plus Retry-After.

### Result

~~~text
POST /v1/execution-bridges/github-actions/executions/:execution_id/attempts/:attempt/result
Authorization: Bearer <bridge-token>

<portable Result v1 JSON>
~~~

The bridge validates execution/attempt identity and then delegates to the existing `GithubPullRequestExecutionFinalizeJob`.

It never bypasses stale checks, lease checks, or finalization fencing.

## Runner-side executor

Do not add another executor implementation.

The workflow starts the existing production image in `executor_service` role:

~~~text
GitHub runner
  |
  +-- postgres container
  |
  +-- RunDiff executor_service container
        RUNDIFF_RUNTIME_ROLE=executor_service
        RUNDIFF_EXECUTOR_SERVICE_ADAPTER=git_clone
        RUNDIFF_EXECUTOR_SERVICE_TOKEN=<job-local random token>
~~~

The job then POSTs the claimed Request to localhost.

Repository authorization:

~~~text
GITHUB_TOKEN
permissions:
  contents: read
~~~

is supplied only to the local executor request as `RunDiff-Repository-Authorization`.

The token is not sent to the RunDiff control plane and is not persisted in the executor request ledger.

GitHub documents that workflow token permissions can be reduced explicitly; this slice requires only read access to repository contents.

## Workflow outline

~~~yaml
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read

jobs:
  rundiff:
    runs-on: ubuntu-24.04
    steps:
      - start local Postgres
      - start RunDiff executor_service image
      - claim exact Request from app.rundiff.com
      - POST Request to localhost executor
      - POST Result to app.rundiff.com
~~~

No customer source checkout by the control plane is required.

## PoC limitations

1. A repository-owned workflow file is required for this first bridge proof.
2. Authentication to the bridge is a repository secret, not GitHub OIDC yet.
3. Control-plane cancellation is durable, but v1 does not cancel the GitHub Actions run through the Actions API.
4. Fork PRs are out of scope because repository secrets and token semantics differ.
5. One scenario/current Review Workload is enough for the first proof.
6. The executor image must be pullable by the external demo workflow (public package or explicit package credential).
7. Standard evidence only; no Performance/Deep claim.
8. GitHub Actions is not made the permanent executor. It is an external orchestrator/compute plan.

## Acceptance

The slice is proven when one external demo PR performs:

~~~text
GitHub opened event
 -> RunDiff durable execution
 -> GitHub Actions claim
 -> local executor_service
 -> portable Result
 -> RunDiff BLOCK

same PR synchronize event after fix
 -> new exact execution
 -> GitHub Actions claim
 -> local executor_service
 -> portable Result
 -> RunDiff ALLOW
~~~

and:

- no manual result injection;
- no GitHub App repository Contents write permission;
- executor repository token is read-only and ephemeral;
- exact attempt/stale/finalization guards remain authoritative in the control plane;
- RunDiff state survives runner destruction.

## After proof

Replace the PoC bridge token with GitHub OIDC.

Then the same external-orchestrator interface can support Buildkite/GitLab/CircleCI without changing portable Request/Result.

Cloudflare Containers should be tested as a second direct managed compute plan after this slice is green.
