# RFC 0007: Repository configuration, review workload, and source-code boundary

## Status

Accepted direction. Implementation is incremental.

## Context

RunDiff should not require a customer to duplicate their entire CI pipeline.

A repository may have:

- a fast focused behavioral workload;
- a large unit-test suite;
- expensive integration tests;
- browser flows;
- benchmark commands;
- agent-generated scenarios;
- legacy tests that take tens of minutes or hours.

The product should let the repository owner define what RunDiff reviews.

At the same time, RunDiff should minimize how much customer source code the control plane needs to see or retain. The control plane needs durable product state, execution metadata, evidence, and policy. It does not need to become a source-code mirror.

This RFC defines canonical repository configuration, workload selection, discovery of tests/scenarios, the source-code privacy boundary, GitHub onboarding without permanent repository-content write access, and local/web/agent configuration flows.

## Decision summary

1. Canonical repository configuration lives at /rundiff.yml.
2. The location is framework-neutral and source-control-neutral. Do not place the canonical file under .github/, Rails config/, Java resources, or another framework-specific directory.
3. Git is the source of truth for execution intent. The control panel is a visual editor for repository-owned configuration, not a hidden competing configuration database.
4. RunDiff does not require the entire customer CI workload. A repository defines a Review Workload.
5. Review Workload may include tests, scenarios, endpoints, CLI commands, browser flows, benchmark profiles, and future agent-generated flows.
6. Workload selection supports explicit, dynamic, and full modes.
7. Workload discovery runs inside an execution environment or customer CI environment, not by copying source code into the Rails control plane for analysis.
8. Source code should remain in the execution environment and be destroyed with that environment unless the customer explicitly chooses a different deployment model.
9. The control plane may receive derived metadata such as test paths, names, tags, durations, framework identity, and evidence. Derived metadata can itself be sensitive and must be treated as customer data.
10. The main GitHub App should keep repository Contents permission read-only for normal operation.
11. Config onboarding must not require permanent Contents: write merely to create rundiff.yml.
12. The preferred hosted onboarding action is Open configuration on GitHub: RunDiff generates the file content and sends the authenticated user into GitHub's own browser UI, where the user creates the branch/commit/PR with their own permissions.
13. Undocumented GitHub URL prefill parameters must not become a durable protocol dependency. The GitHub browser handoff must be isolated behind an adapter and verified against current GitHub behavior.
14. Local CLI and AI-agent flows edit the same /rundiff.yml.
15. A RunDiff gem/package is not required merely to discover or select tests. Language/framework packages are optional evidence adapters when deeper semantic instrumentation is valuable.
16. Secrets, channel credentials, provider tokens, and organization-private mappings do not belong in rundiff.yml.

## Canonical location

For every supported repository type:

~~~text
Rails   -> /rundiff.yml
Go      -> /rundiff.yml
Java    -> /rundiff.yml
Python  -> /rundiff.yml
Node    -> /rundiff.yml
Rust    -> /rundiff.yml
~~~

Example:

~~~text
my-project/
├── .git/
├── app/
├── config/
├── spec/
├── Gemfile
├── Dockerfile
└── rundiff.yml
~~~

The file is visible rather than hidden intentionally. It is a repository contract, like a Dockerfile or other first-class project configuration.

## Repository-owned intent

The control plane may keep a draft while a user configures RunDiff in the UI, but the durable execution policy comes from the repository revision being reviewed.

Principle:

> The control plane edits configuration through Git, not around Git.

Benefits:

- configuration changes are code-reviewed;
- branch behavior is reproducible;
- old reviews can be explained from the commit;
- CODEOWNERS and branch protection apply naturally;
- local tooling and SaaS use the same contract;
- agents can edit configuration without a SaaS-only API.

A hidden SaaS-only selection such as "run these 17 tests" must not silently override the committed file.

## Review Workload

The customer-facing concept is Review Workload, not merely Tests to run.

Possible workload items include:

- RSpec / Minitest examples;
- pytest / Jest / Vitest tests;
- Go tests;
- JUnit / Maven / Gradle tests;
- Cargo tests;
- Playwright or browser flows;
- HTTP/gRPC scenarios;
- CLI commands;
- k6 or benchmark profiles;
- explicit RunDiff scenarios;
- future agent-generated flows.

RunDiff should run what is useful for behavioral comparison, not automatically duplicate every CI job.

## Workload selection modes

### Explicit

Example:

~~~yaml
version: 1

review:
  include:
    - path: spec/requests/checkout/**
    - path: spec/services/payments/**
    - tag: rundiff
  exclude:
    - tag: slow
    - path: spec/legacy/**
~~~

### Dynamic

Dynamic selectors express intent rather than filenames.

Example:

~~~yaml
version: 1

review:
  include:
    - changed
    - related
    - path: spec/smoke/**
~~~

changed and related are product semantics, not yet a committed matching algorithm.

A future resolver may use changed files, test-to-code coverage, dependency graphs, historical co-change, trace relationships, framework conventions, explicit scenario ownership, and agent recommendations.

Dynamic selection must remain explainable. The UI should show why a test or scenario was selected.

### Full

Example:

~~~yaml
version: 1

review:
  include:
    - all
~~~

Full-suite execution remains supported for customers who explicitly want it.

## Evidence selection

Review Workload and Evidence Depth are independent.

Example:

~~~yaml
version: 1

review:
  include:
    - changed
    - related
    - path: spec/smoke/**

evidence:
  depth: performance
~~~

Evidence Depth remains defined in RFC 0004: Standard, Performance, and Deep.

## Workload discovery

The control plane should not clone a private repository merely to enumerate tests.

Preferred flow:

~~~text
short-lived repository capability
        |
        v
execution environment
        |
        +--> clone exact revision
        |
        +--> detect framework/toolchain
        |
        +--> run discovery adapter
        |
        +--> source remains in environment
        |
        +--> emit derived workload catalog
                    |
                    v
             control plane
~~~

Possible discovery adapters:

~~~text
RSpecDiscovery
MinitestDiscovery
PytestDiscovery
JestDiscovery
VitestDiscovery
GoTestDiscovery
JUnitDiscovery
CargoTestDiscovery
PlaywrightDiscovery
~~~

The names are illustrative, not public contracts.

Discovery should use framework-native listing APIs or manifests where practical rather than parsing arbitrary source in the control plane.

## Workload catalog

A derived catalog may contain:

~~~json
{
  "framework": "rspec",
  "items": [
    {
      "id": "stable-or-versioned-id",
      "kind": "test",
      "path": "spec/requests/checkout_spec.rb",
      "name": "Checkout API creates an order",
      "tags": ["request"],
      "estimated_duration_ms": 1820
    }
  ]
}
~~~

The exact schema is future work.

The catalog exists to support workload selection UI, duration estimates, Review Credit estimates, changed/related recommendations, routing and ownership, and historical repository learning.

## Metadata is still customer data

Source-code minimization does not mean metadata is harmless.

For example, test paths and names can reveal sensitive domain structure.

Therefore:

- catalogs need retention controls;
- access must follow repository/account authorization;
- logs must not dump catalog payloads casually;
- Enterprise/BYOC may request reduced metadata or local-only catalogs;
- future Metadata Restricted mode may replace names/paths with opaque IDs where useful.

RunDiff must not market "we never receive repository data" if it receives test names, file paths, traces, SQL fingerprints, or similar evidence.

A more accurate trust statement is:

> RunDiff does not need to persist repository source code in the control plane. It stores the metadata and evidence required to produce a Behavioral Review.

## Source-code boundary

For RunDiff-managed compute:

~~~text
GitHub
  -> short-lived repository-scoped read capability
  -> disposable execution environment
       -> clone
       -> discover
       -> execute
       -> collect evidence
       -> cleanup
~~~

The Rails control plane does not need the repository checkout.

The execution workspace is disposable.

The clone credential remains short-lived, repository-scoped, read-only where possible, and out of durable portable Request/Result payloads.

This extends the existing repository-capability boundary documented in docs/executor.md.

For Customer Hosted / external CI:

~~~text
customer repository
  -> customer runner / VPC
  -> RunDiff executor/instrumentation
  -> normalized metadata/evidence
  -> RunDiff control plane
~~~

This path can keep source code entirely inside customer infrastructure.

## GitHub setup flow

The preferred hosted onboarding is:

~~~text
Sign in to RunDiff
  -> Install read-oriented RunDiff GitHub App
  -> Select repository
  -> discover workload in execution environment
  -> configure Review Workload in RunDiff UI
  -> preview rundiff.yml
  -> Open configuration on GitHub
  -> user reviews file in GitHub UI
  -> user creates branch/commit
  -> user opens PR against default branch
  -> normal branch protection/CODEOWNERS review
  -> merge
~~~

The primary CTA may be:

~~~text
Open configuration on GitHub
~~~

The UI should state clearly:

~~~text
RunDiff will open GitHub with this configuration.
You will review and commit the change using your GitHub account.
~~~

## No permanent repository-content write permission for setup

The normal RunDiff GitHub App should not gain Contents: write just to automate configuration.

RunDiff can still require write permissions for non-content GitHub product surfaces such as Checks or PR comments; this decision specifically concerns repository file contents.

No headless branch/commit/file creation is required for the standard config flow.

The browser handoff has useful properties:

- the user is the actor;
- GitHub enforces their permissions;
- branch protection applies;
- fork behavior remains GitHub-native;
- no repository write token needs to be stored by RunDiff;
- the user explicitly accepts the configuration change.

## GitHub URL integration

GitHub supports browser workflows for creating files and pull requests. Some URL-prefill behavior has existed historically.

However:

- undocumented query parameters must not be treated as a stable API;
- RunDiff should encapsulate GitHub URL generation;
- integration tests should verify current behavior;
- if GitHub changes the flow, RunDiff should degrade to a GitHub-native multi-step editor rather than request broad permanent write scope.

The product requirement is:

> No copy/paste is required in the normal happy path.

The implementation is allowed to require a small number of explicit GitHub UI confirmations.

## Semantic Git branch and PR naming

Suggested initial setup semantics:

~~~text
branch:
  chore/rundiff-setup

commit:
  chore: configure RunDiff

pull request:
  Configure RunDiff
~~~

Subsequent UI-driven updates:

~~~text
branch:
  chore/rundiff-update-config

commit:
  chore: update RunDiff configuration

pull request:
  Update RunDiff configuration
~~~

Collision-safe suffixes may be added.

Before offering a setup PR, the control plane should detect existing rundiff.yml, an existing open RunDiff configuration PR, the default branch, and current installation/repository identity.

## Control-panel UI

Suggested flow:

~~~text
Configure RunDiff

Repository
  acme/payments

Detected
  Rails
  RSpec
  PostgreSQL
  Redis

Review workload
  ( ) Recommended: changed + related
  ( ) Select manually
  ( ) Full suite

Evidence
  ( ) Standard
  ( ) Performance
  ( ) Deep

Estimated workload
  14 items
  ~3m 40s wall time
  ~N Review Credits

Configuration preview
  rundiff.yml

[ Open configuration on GitHub ]
~~~

For an existing config:

~~~text
Configured from rundiff.yml
[ Edit configuration ]
~~~

Editing through the control panel again produces a Git change, not a hidden override.

## Local CLI and agent flow

Local setup remains first-class:

~~~text
rundiff init
rundiff configure
~~~

An AI coding agent can also create or edit /rundiff.yml.

All configuration paths converge on one source of truth:

~~~text
Web UI ------> GitHub UI / PR ---+
CLI ---------> local file -------+--> /rundiff.yml
AI agent ----> repository edit --+
~~~

## Package / gem boundary

A RunDiff language package is not required merely to install the GitHub App, discover the test framework, list tests/scenarios where native discovery is possible, select Review Workload, or execute black-box commands.

A package/gem may be valuable for semantic evidence such as SQL, jobs, mail, framework events, allocations, and richer source attribution.

Where safe, RunDiff should prefer temporary execution-time instrumentation over forcing a permanent application dependency.

## Privacy modes

The base hosted product can provide a strong source-minimization boundary without being Enterprise-only.

### Hosted

Control plane may receive test/scenario names and paths, tags, timing/resource metadata, normalized evidence, and artifacts explicitly retained by policy.

It does not persist the full repository checkout.

### Metadata Restricted

Potential future mode:

- opaque item IDs;
- redacted paths/names;
- reduced catalogs;
- local mapping in executor/customer environment.

### Customer Hosted / Enterprise

Potential mode:

- source;
- discovery;
- some evidence processing;
- sensitive artifacts;

remain inside customer infrastructure.

Only required normalized result, status, billing, and policy metadata leave the customer boundary.

Enterprise features can add DPA, region controls, private networking, custom retention, audit, SSO/SCIM, provider allow-lists, and dedicated execution. The source-minimization architecture itself is not reserved for Enterprise.

## Consequences

### Positive

- customers do not need to run all CI;
- configuration is reproducible and reviewable;
- no framework-specific config paths;
- standard onboarding can avoid permanent repository-content write access;
- source-code retention in the control plane is minimized;
- workload selection works for freelancers and enterprises;
- dynamic selection can improve compute economics;
- AI-generated candidate volume fits the same workload contract.

### Costs

- discovery adapters become real product surface;
- catalogs need authorization and retention policy;
- dynamic related selection needs explainability;
- GitHub browser integration needs ongoing compatibility tests;
- repository-owned config creates migration/versioning responsibilities;
- metadata-restricted modes add complexity.

## Non-goals

This RFC does not define the final rundiff.yml schema, guarantee current GitHub URL query parameters forever, require a RunDiff gem for every repository, require AI to choose tests, require source-code upload to the control plane, make the control panel a second source of configuration truth, define final pricing or Review Credit conversion, or define notification routing.

## Open questions

1. What is the stable item ID for tests that move or are renamed?
2. How does related work in v1?
3. How much workload catalog metadata should be durable by default?
4. Should workload catalogs be encrypted separately from ordinary product metadata?
5. Which discovery adapters are required after RSpec/Minitest?
6. How do fork PRs affect config and workload discovery?
7. What GitHub browser handoff is reliable enough for the first production UX?
8. How should branch-protected repos with mandatory PR templates be handled?
9. How should config schema migration work across old branches?
10. Which semantic instrumentation can be injected without repository dependencies?

## Related work

- RFC 0002: Runner adapter contract
- RFC 0004: Execution planning, compute, placement, and evidence strategy
- RFC 0006: Portable execution and multi-source evidence
- RFC 0008: Ownership-aware finding routing
- docs/executor.md
- docs/subject-environments.md
- docs/github.md


## GitHub identity versus installation

RunDiff should treat two GitHub relationships separately.

### User authentication

Purpose:

~~~text
Who is this RunDiff user?
~~~

Use the minimum identity/profile authorization required for account/session behavior.

Do not request broad repository write scope merely for configuration onboarding.

### GitHub App installation

Purpose:

~~~text
Which repositories may RunDiff observe/review?
~~~

Repository access comes from the GitHub App installation and its selected repositories/permissions.

This separation means a user can sign in to the RunDiff control panel without automatically granting RunDiff repository access, and repository access can be installed/revoked independently of user login.

Configuration PR creation remains a browser handoff to GitHub under the user's existing GitHub session rather than a reason to persist a broad OAuth repository-write token.
