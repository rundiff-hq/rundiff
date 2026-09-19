# RunDiff

**Tests passed. Behavior changed.**

RunDiff is a behavioral change validation platform. It runs the same scenario against two software subjects, captures execution evidence, and explains what changed.

The product starts as a Rails 8.1 monolith on purpose. Portable contracts and comparison logic stay outside Rails-specific code so the CLI, protocol, recorders, drivers, and ingestion components can be extracted later without redesigning the model.

## First vertical slice

```text
main + scenario ─┐
                 ├─> evidence ─> behavioral diff ─> GitHub
PR   + scenario ─┘
```

Both functional executions may pass. RunDiff can still detect changes in latency, SQL queries, background jobs, external side effects, memory, network behavior, or other runtime evidence.

## Dogfood RunDiff with RunDiff

The Rails app now has a real local-only execution probe. It runs two HTTP executions through the Rails middleware stack, propagates RunDiff correlation headers, observes Rails notifications, and feeds captured evidence into the same portable behavioral diff engine.

```bash
bin/rails db:prepare
bin/rails rundiff:dogfood
```

The demo intentionally keeps both executions functionally green while the candidate performs more SQL, enqueues more jobs, emits a duplicate email side effect, and takes longer.

The capture path is real:

```text
Rack request
  -> X-RunDiff-Run-Id / X-RunDiff-Execution-Id / X-RunDiff-Subject
  -> Rails middleware + controller
  -> ActiveSupport::Notifications
       SQL / ActiveJob / request / side effects
  -> RunDiff::Rails::EvidenceCollector
  -> RunDiff::BehavioralDiff
```

## Portable diff

The core comparison command remains Rails-independent:

```bash
bin/rundiff diff \
  --baseline examples/behavioral-diff/main.json \
  --candidate examples/behavioral-diff/candidate.json
```

Machine-readable output:

```bash
bin/rundiff diff \
  --baseline examples/behavioral-diff/main.json \
  --candidate examples/behavioral-diff/candidate.json \
  --format json
```

## Behavioral Review

Run the full customer-like Rails + SQLite demo with one command:

```bash
bin/rundiff demo --color always
```

A complete A/B execution payload can also be rendered through the same product-facing review surface used by GitHub:

```bash
bin/rundiff review --input tmp/demo/block.json
bin/rundiff review --input tmp/demo/block.json --format markdown
bin/rundiff review --input tmp/demo/block.json --format json
```

See `docs/demo-behavioral-review.md` for the local, Lab, and remote GitHub Actions demo runbook.

## Rails repository onboarding

The first v0.1 onboarding contract is intentionally small. A customer Rails repository may add:

```yaml
version: 1
scenario:
  path: /orders/42
subject:
  persistence: auto
```

RunDiff uses the candidate-head `rundiff.yml` as the shared A/B scenario contract and discovers supported persistence independently in each exact Git worktree. Rails + PostgreSQL and Rails + SQLite are currently recognized. Unsupported or ambiguous persistence fails explicitly instead of silently defaulting to PostgreSQL.

The control plane exposes `/onboarding` as the customer-facing entry point: install the GitHub App, copy the minimal configuration, then open or update a pull request. The local `bin/setup-github-app` flow is developer/operator bootstrap and is not part of customer onboarding.

See `docs/onboarding.md` for the current five-minute onboarding shape and deliberate limits.

## Repository map

- `docs/` - product thesis, architecture, decisions, RFCs, demo, roadmap
- `schemas/` - machine-readable execution/result contracts
- `lib/rundiff/` - portable core plus Rails adapters/probes behind explicit namespaces
- `app/` - Rails product shell and dogfood target
- `examples/` - deterministic demo evidence

## Runtime

- Ruby 3.4.10
- Rails 8.1.3.1
- PostgreSQL control plane

## Current status

The GitHub App execution path, durable executor boundary, exact Git A/B worktrees, Rails runtime evidence, PostgreSQL and SQLite customer subject environments, and GitHub Check/PR feedback loop are real and exercised in CI and in a separate live customer-like sandbox. The current productization target is a public hosted GitHub App that turns `/onboarding` into a cross-account install-to-first-review path without operator intervention.

See `docs/current-state.md` for the canonical snapshot of what is already proven, what is still blocked on live production state, which older assumptions are superseded, and which architectural/history records are intentionally retained.
