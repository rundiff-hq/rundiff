# Arbitrary Rails bootstrap

This document defines the first RunDiff v0.1 customer-runtime bootstrap contract.

The goal is to execute a normal Rails repository without requiring that repository to commit RunDiff runtime files or pre-install its bundle on the executor host.

## Boundary

For each exact Git worktree, RunDiff owns these phases:

1. inspect the customer runtime contract
2. verify the executor Ruby is compatible
3. select the Bundler version declared by `Gemfile.lock`
4. install/check gems into a disposable executor-owned bundle path
5. discover the Rails persistence adapter
6. prepare isolated persistence
7. invoke a tool-owned portable Rails capture

The customer repository remains unchanged.

## v0.1 supported contract

- Rails application with `config/application.rb` and `bin/rails`
- committed `Gemfile` and `Gemfile.lock`
- Ruby version compatible with the executor Ruby
- PostgreSQL or SQLite persistence
- scenario configured by `rundiff.yml`
- request-level evidence: wall time, process/thread CPU, SQL queries, enqueued jobs, delivered emails, Net::HTTP requests, runtime errors

Async worker-stage evidence remains unavailable unless the richer subject-owned instrumentation capability is present.

## Dependency isolation

Bundle state is stored outside the customer worktree under an executor-owned cache keyed by the lockfile digest. `BUNDLE_APP_CONFIG` is also outside the worktree. RunDiff never runs `bundle update`, and a committed lockfile is treated as immutable.

## Ruby compatibility

RunDiff reads `.ruby-version` when present and the `RUBY VERSION` section in `Gemfile.lock` when available. The first v0.1 executor image does not install arbitrary Ruby versions dynamically. If the requested major/minor Ruby line differs from the executor Ruby, bootstrap fails with an explicit compatibility error instead of attempting execution under the wrong interpreter.

Dynamic multi-Ruby executor images are a later deployment concern and do not belong in the portable Request/Result protocol.

## Tool-owned capture

The portable capture script lives in the RunDiff image/tool checkout and boots the customer Rails application from its worktree. It subscribes to standard Rails/ActiveSupport notifications and instruments Net::HTTP locally for the duration of the scenario.

This deliberately does not require customer models, migrations, middleware, initializers, or `lib/rundiff/*` files.

The richer dogfood runtime remains supported separately and can expose durable async/worker timing when a subject explicitly owns those capabilities.
