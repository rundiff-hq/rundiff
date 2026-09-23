# VS19 - External Rails Zero-Operator Review

Status: planned

## Goal

Prove the first customer-shaped RunDiff workflow on an external Rails repository with no operator-triggered execution.

Target lifecycle:

```text
install RunDiff GitHub App
-> grant one Rails repository
-> add candidate-owned rundiff.yml
-> open pull request with deliberate behavioral regression
-> GitHub webhook
-> Cloudflare control plane
-> automatic dedicated executor dispatch
-> exact baseline + candidate execution
-> BLOCK publication
-> push behavioral fix to the same pull request
-> synchronize webhook
-> automatic re-execution
-> ALLOW publication
```

The acceptance proof must not require a manual GitHub Actions run, proof workflow, local executor command, operator-side queue mutation, or hand-authored Result v1.

## Customer contract

Repository-side configuration should remain minimal:

```yaml
version: 1
scenario:
  path: /orders/42
subject:
  persistence: auto
```

The external repository must not need:

- a RunDiff gem;
- a RunDiff GitHub Actions workflow;
- RunDiff middleware or initializer;
- executor credentials;
- Docker-specific RunDiff wiring;
- operator assistance after installation and configuration.

## Scope

VS19 includes only the capability required to prove a Rails customer path:

- external Rails repository;
- SQLite or PostgreSQL persistence;
- automatic `pull_request/opened` handling;
- automatic `pull_request/synchronize` handling;
- exact baseline and candidate SHA authority;
- deterministic scenario execution;
- durable BLOCK / ALLOW publication;
- one updateable PR comment;
- one authoritative GitHub Check;
- Review Detail on the hosted control plane;
- explicit INFRA_FAILURE when the repository cannot be prepared or executed;
- install-to-first-review timing evidence.

## Non-goals

Do not expand VS19 with:

- Playwright;
- OpenTelemetry trace ingestion;
- eBPF;
- AI root-cause analysis;
- billing;
- multi-provider placement;
- performance-confidence sampling;
- Review Workload selection beyond the minimum explicit scenario;
- additional runtime languages.

Those remain later slices.

## Acceptance fixture

Use a public external Rails fixture repository owned outside the RunDiff production repository.

The fixture must contain a small deterministic route with observable behavior and a persistence dependency representative of a normal Rails app.

Preferred proof sequence:

```text
main
  correct behavior

PR commit A
  deliberate regression
  -> RunDiff BLOCK

PR commit B
  behavioral fix
  -> RunDiff ALLOW
```

The same pull request must be used for both phases.

## Proof invariants

Acceptance is complete only when all of the following are true:

1. The GitHub App receives the real external repository webhook.
2. The candidate identity comes from GitHub, not an operator-supplied SHA.
3. The Cloudflare control plane creates the execution automatically.
4. The dedicated executor workflow starts automatically.
5. The Go executor exact-claims the persisted attempt.
6. Baseline and candidate are checked out as exact Git revisions.
7. The Rails subject starts without RunDiff-specific customer instrumentation.
8. The deliberate regression publishes BLOCK.
9. A push to the same PR produces a synchronize event.
10. The fixed candidate publishes ALLOW.
11. The existing RunDiff PR comment is updated rather than duplicated.
12. The authoritative Check belongs to the RunDiff GitHub App.
13. No manual proof workflow or local command is involved.
14. Production evidence retains webhook delivery, candidate SHAs, execution IDs, workflow run IDs, result identities, publication identities, and elapsed time.

## Failure semantics

Customer-code or repository-preparation failures must not silently become BLOCK.

Use:

```text
behavioral regression -> BLOCK
behavior accepted      -> ALLOW
execution/platform failure -> INFRA_FAILURE
```

The Review Detail must make the distinction visible.

## Definition of done

A new external Rails repository can go from **Install RunDiff** to a first Behavioral Review, then from a deliberately broken candidate to a fixed candidate, without RunDiff operator intervention:

```text
Install
-> Configure
-> Open PR
-> BLOCK
-> Push fix
-> ALLOW
```

Retain the complete Production Proof v2 evidence as the canonical VS19 acceptance artifact.

## After VS19

Once this customer path is production-proven, the next product slice should be repository-owned Review Workload selection rather than additional executor internals.
