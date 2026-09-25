# VS19 - Zero-Operator External Rails Review

Status: implementation ready

## Goal

Prove the first customer-shaped Rails workflow from GitHub App installation to a completed Behavioral Review with no RunDiff operator action between the customer pull-request events and the final GitHub feedback.

Target lifecycle:

```text
install RunDiff GitHub App
-> grant access to external Rails repository
-> repository contains minimal rundiff.yml
-> open PR with deliberate behavioral regression
-> GitHub pull_request.opened webhook
-> Cloudflare control plane
-> automatic dedicated GitHub Actions dispatch
-> Go executor claims exact attempt
-> exact baseline + candidate Rails execution
-> Result v1
-> GitHub Check + updateable PR comment = BLOCK
-> customer pushes the fix
-> GitHub pull_request.synchronize webhook
-> same automatic pipeline
-> GitHub Check + same updateable PR comment = ALLOW
```

## Product acceptance

VS19 is complete only when one external Rails repository proves all of the following without a manual workflow dispatch, proof-only workflow, local runner, or operator-side API call:

1. GitHub App installation grants access to the repository.
2. A candidate-only RunDiff configuration is sufficient to start the review.
3. `pull_request.opened` creates an exact RunDiff execution automatically.
4. A deliberate regression produces a deterministic `BLOCK`.
5. The GitHub Check and PR comment identify the same candidate and execution.
6. Pushing the behavioral fix to the same PR produces `pull_request.synchronize`.
7. The synchronize event creates a new exact execution automatically.
8. The fixed candidate produces `ALLOW`.
9. The existing RunDiff PR comment is updated rather than duplicated.
10. The review detail is readable from the hosted RunDiff control plane.
11. Any customer bootstrap/runtime failure becomes explicit `INFRA_FAILURE`, never a false BLOCK/ALLOW.
12. Install-to-first-review elapsed time is retained as production evidence.

## External fixture

Selected fixture: `sergii/happytest`.

The repository is outside `rundiff-hq`, so the proof exercises the real GitHub App installation boundary. The acceptance work is isolated from the repository default branch:

```text
main:                      6f5d81e482bd176e494cb626418f56e4baca6e41
rundiff/vs19-base:         8b9228e69bd7782a821267d5908f24fbff5dc9db
rundiff/vs19-regression:   e13ff1cdc4ba72668335688c08bbf974880d30b9
```

Fixture runtime:

- Rails 8.0.2;
- repository Ruby 3.4.4;
- SQLite;
- committed Gemfile.lock with x86_64 Linux platform;
- portable Rails sensor;
- deterministic `POST /rundiff-fixture` scenario.

The base fixture returns HTTP 200. The regression branch returns HTTP 503 and adds candidate-owned `rundiff.yml`. The resulting new `errors` signal maps to the decision-relevant `NEW_RUNTIME_ERROR` rule and is expected to BLOCK.

The fixture must stay intentionally small:

- Rails application;
- SQLite for this first external proof;
- one deterministic HTTP or application scenario;
- one deliberate candidate-only behavioral regression;
- one follow-up fixing commit;
- minimal dependencies;
- no RunDiff GitHub Actions workflow in the customer repository.

The fixture is a long-lived acceptance/demo target, not a benchmark application.

## Configuration contract

The happy path should require only repository-owned configuration, for example:

```yaml
version: 1

scenario:
  path: /orders/42

subject:
  persistence: auto
```

VS19 should not require a RunDiff gem, initializer, middleware, executor configuration, Docker setup, or customer-owned CI workflow.

If the current executor needs a narrower temporary configuration for the first proof, record that explicitly and keep it candidate-owned.

For the first proof the central dispatch runner provisions Ruby 3.4.1 and the Go bootstrap enforces compatibility with the repository-declared Ruby major/minor line. `sergii/happytest` declares Ruby 3.4.4, so it is compatible without modifying the customer default branch.

## Implementation slices

### 1. External Rails capability

Make the existing Go executor path work against the selected external Rails fixture:

- clone exact baseline and candidate SHAs;
- detect Rails runtime;
- bootstrap dependencies;
- prepare subject persistence;
- start the subject;
- wait for readiness;
- execute the selected scenario;
- collect deterministic evidence;
- compare baseline and candidate;
- submit Result v1.

Prefer existing executor capabilities. Do not add a second execution path.

### 2. GitHub event continuity

Verify both events use the same production path:

```text
pull_request.opened
pull_request.synchronize
```

For both events retain:

- GitHub delivery GUID;
- installation id;
- repository;
- PR number;
- base SHA;
- candidate SHA;
- RunDiff review id;
- execution id;
- attempt number;
- dispatch workflow run id;
- final decision.

### 3. Publication continuity

The external PR must expose:

- one stable RunDiff Check name;
- one updateable RunDiff PR comment;
- BLOCK on the regression commit;
- ALLOW on the fixing commit;
- candidate and execution identity in both surfaces;
- hosted review detail for the current review.

### 4. Failure semantics

Exercise at least one controlled bootstrap/runtime failure on the fixture or a dedicated fixture branch and prove:

```text
execution cannot run
-> INFRA_FAILURE
-> actionable diagnostic
-> no behavioral BLOCK/ALLOW claim
```

This failure proof may be performed after the main BLOCK -> ALLOW acceptance, but before VS19 is declared complete.

## Canonical acceptance sequence

```text
A. Install App on external Rails fixture
B. Add minimal rundiff.yml
C. Open PR containing deliberate regression
D. Observe automatic opened execution
E. Retain BLOCK evidence
F. Push only the behavioral fix
G. Observe automatic synchronize execution
H. Retain ALLOW evidence
I. Verify one stable comment, Check continuity, and hosted review detail
J. Retain install-to-first-review and synchronize-to-review elapsed times
```

## Evidence record

The final proof document must retain at least:

```text
fixture repository
PR number
installation id
opened delivery GUID
BLOCK candidate SHA
BLOCK execution id
BLOCK attempt
BLOCK workflow run
BLOCK final decision
synchronize delivery GUID
ALLOW candidate SHA
ALLOW execution id
ALLOW attempt
ALLOW workflow run
ALLOW final decision
stable PR comment id
Check names/conclusions
hosted review URLs
install-to-first-review elapsed time
synchronize-to-review elapsed time
production Worker version
main RunDiff commit
```

Secrets and repository tokens must never be recorded.

## Non-goals

Do not expand VS19 into:

- Playwright/browser scenarios;
- new OpenTelemetry evidence;
- eBPF or Deep mode;
- a second compute provider;
- billing or Review Credits;
- workload selection beyond the one explicit scenario;
- AI root-cause analysis;
- generalized Rails application discovery;
- performance-confidence sampling;
- customer-owned GitHub Actions integration.

Those remain later slices.

## Definition of done

A person can install RunDiff on an external Rails repository, open a deliberately bad pull request, receive a RunDiff BLOCK, push the fix, and receive ALLOW on the same PR without RunDiff operator intervention after the GitHub events are generated.

That is the first zero-operator customer-shaped Rails Behavioral Review.
