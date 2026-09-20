# Product thesis

RunDiff shows what a software change actually changed before that change is accepted.

A change can pass every assertion and still double latency, create N+1 queries, enqueue duplicate jobs, send duplicate notifications, alter webhook payloads, increase memory, or change network behavior.

Traditional testing primarily answers whether assertions passed. Observability primarily explains running systems. RunDiff connects change validation with execution evidence before merge or acceptance.

~~~text
Change / candidate
  -> Review Workload
  -> baseline + candidate executions
  -> evidence
  -> Behavioral Diff
  -> decision
  -> ownership-aware routing
~~~

## Product unit: Behavioral Review

A Behavioral Review is the customer-facing unit of value.

It is intentionally broader than a pull request.

A review may evaluate:

- a human PR;
- an AI-generated patch;
- a candidate branch;
- a merge-queue candidate;
- one of many generated solutions;
- a local or agent-produced change.

This matters because AI-assisted development may create far more candidate changes than historical human PR workflows.

## Review only what matters

RunDiff is not CI x 2.

A customer should not be forced to duplicate an entire existing CI suite just to get behavioral evidence.

The repository defines a Review Workload that may contain:

- selected tests;
- changed or related tests;
- browser/API scenarios;
- CLI commands;
- benchmark profiles;
- full-suite execution when explicitly desired;
- future agent-generated scenarios.

The durable principle is:

> Run what matters for this change, not everything that happens to exist in CI.

## Product dimensions

Review volume and Evidence Depth are independent.

### Review volume

Working commercial labels include Preview, Review 250, Review 500, Review 1000, and Enterprise.

Raw wall-clock minutes are not a durable customer billing unit because machine size and parallelism change aggregate compute.

Review Credits are the working normalized managed-compute abstraction.

The primary human explanation should be estimated Behavioral Reviews, especially after RunDiff has learned a repository's normal workload.

### Evidence Depth

Working levels:

- Standard - behavioral evidence;
- Performance - controlled resource/performance comparison with confidence gating;
- Deep - explicitly supported host/kernel/system evidence.

Evidence Depth is not automatically tied to Review Volume.

## Execution philosophy

Most customers should not have to choose infrastructure.

The default experience is:

~~~text
Execution
  Automatic
~~~

RunDiff's Workload Profiler and Placement Engine construct an Execution Plan from workload requirements, provider/runtime capabilities, policy, stability, cost, parallelism, and Evidence Depth.

The architecture may use RunDiff-managed compute, customer CI, BYOC, or another compatible execution path without changing the customer-facing Behavioral Review model.

## Repository-owned configuration

Canonical repository configuration is:

~~~text
/rundiff.yml
~~~

Git is the source of truth for execution intent.

The control panel is a visual editor for that repository-owned configuration, not a second hidden policy database.

Hosted onboarding should let a user configure RunDiff in the control panel and then open the prepared configuration in GitHub's browser UI, where the user creates the Git change with their own permissions.

## Source-code minimization

RunDiff executes customer code, but the Rails control plane does not need to persist the customer repository checkout.

Preferred hosted boundary:

~~~text
repository
  -> short-lived read capability
  -> disposable execution environment
       -> discover workload
       -> execute
       -> emit metadata/evidence
       -> destroy workspace
  -> RunDiff control plane
~~~

Derived metadata is still customer data.

The accurate trust statement is:

> RunDiff does not need to persist repository source code in the control plane. It stores the metadata and evidence required to produce a Behavioral Review.

## Ownership-aware delivery

A useful finding should reach the team that owns the affected behavior.

CODEOWNERS is the preferred first ownership source.

RunDiff may later combine:

- source ownership;
- scenario ownership;
- service catalogs;
- organization mappings.

Ownership is not causality. RunDiff can say who owns an affected path or behavior without claiming that team caused the regression.

GitHub remains the primary PR review surface. External Slack, Teams, Discord, Telegram, email, webhook, ticketing, incident, or agent delivery is policy-controlled.

## Principles

1. Evidence over assertions.
2. Compare, do not merely observe.
3. Bring your own tests and scenarios.
4. Do not require the whole CI suite.
5. Scenario identity is independent of the driver.
6. GitHub is a decision surface; RunDiff is the investigation surface.
7. Agent-readable by design.
8. Prefer OTLP and W3C Trace Context over custom protocols.
9. Rails first, extraction-ready.
10. No silent baseline acceptance.
11. Separate product regressions from infrastructure failures.
12. Git is the source of truth for repository execution intent.
13. Minimize source-code persistence in the control plane.
14. Automatic placement should be explainable before it becomes predictive.
15. Performance claims must respect measured noise.
16. Ownership is routing context, not blame.
17. Route important findings intentionally; do not broadcast everything.
18. LLM explanation is optional and downstream of deterministic evidence.

RunDiff is not a new test framework. Playwright, Capybara, Cypress, Maestro, RSpec, Minitest, pytest, Jest, Go tests, cargo test, arbitrary CLI commands, k6 profiles, and agent-driven flows can all participate in a RunDiff Behavioral Review.
