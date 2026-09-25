# RFC 0012: Verification Plan as a first-class change artifact

## Status

Proposed research direction.

Captured: 2026-09-25

External signal: Cursor Rollouts and Security Reviewer.

This RFC is append-only research material. It does not rewrite or supersede existing RunDiff RFCs, product architecture, or roadmap. Any promotion into canonical product behavior requires a later consolidation decision.

## Why this RFC exists

RunDiff already treats a software change as something that can be executed in baseline and candidate environments, observed through evidence, compared behaviorally, and reduced to findings before production.

A new adjacent market signal makes one missing artifact more explicit: the verification plan that connects a code change to the evidence required to decide whether that change is acceptable.

Cursor's Rollouts product, announced on 2026-09-23, reads a PR diff before merge, writes a monitoring plan containing risks, expected effects, and instrumentation gaps, then compares the planned signals against a pre-deploy baseline after deployment. When it detects a regression it can identify a suspected change and, depending on configuration, notify an author, pause a progressive rollout, or prepare a revert PR.

Source:

- https://cursor.com/blog/rollouts-and-security-reviewer

The useful lesson for RunDiff is not "copy Rollouts". The useful lesson is that a change-aware verification plan can be a durable first-class artifact rather than an implicit collection of checks.

## Candidate model

Evaluate a first-class `Verification Plan` associated with a review/change:

~~~text
code change
    |
    v
agent or human proposes
Verification Plan
    |
    +--> expected effects
    +--> forbidden effects
    +--> required evidence
    +--> acceptable deltas
    +--> missing instrumentation
    +--> scenario requirements
    +--> pre-deploy checks
    +--> post-deploy checks
    |
    v
evidence + deterministic evaluation
~~~

The plan should be editable and reviewable. Generation may be agentic; authoritative evaluation should remain grounded in explicit evidence and deterministic policy where possible.

## Candidate contract shape

Illustrative only:

~~~yaml
change:
  repository: example/service
  revision: abc123

expectations:
  - signal: http.checkout.latency
    expectation: unchanged
    tolerance:
      relative: 0.10

  - signal: db.query.count
    expectation: bounded_increase
    tolerance:
      relative: 0.10

  - signal: payments.success_rate
    expectation: unchanged

forbidden_effects:
  - new_outbound_host
  - authorization_regression

required_evidence:
  - http
  - sql
  - runtime_resources

instrumentation_gaps: []
~~~

This is not a schema proposal yet.

## Pre-deploy and post-deploy continuum

Cursor Rollouts is primarily valuable across PR -> deploy -> production telemetry.

RunDiff's current differentiator remains pre-production differential execution:

~~~text
PR
 |
 +--> baseline execution
 +--> candidate execution
 |
 +--> same scenario
 +--> evidence
 +--> behavioral diff
 +--> findings
 +--> ALLOW / BLOCK / INFRA_FAILURE
~~~

A future Verification Plan could bridge pre-deploy and post-deploy verification without collapsing the products:

~~~text
                     Verification Plan
                            |
              +-------------+-------------+
              |                           |
              v                           v
          RunDiff                    Operational
       before production           after production
              |                           |
       baseline/candidate          expected/observed
              |                           |
              +---------- evidence -------+
~~~

RunDiff does not need to become a production observability platform for this relationship to be useful.

## Agent generation vs deterministic authority

A useful division of responsibility is:

~~~text
agent
  proposes risks, expectations, scenarios, and missing evidence

human
  edits / approves when required

runtime
  collects evidence

deterministic evaluators
  compute deltas, invariants, and policy results

policy
  decides ALLOW / BLOCK / action
~~~

The LLM should not become the only authority for whether a candidate is safe.

This keeps RunDiff explainable and reproducible while still benefiting from code-aware agents.

## Missing instrumentation as a finding

Cursor explicitly treats missing instrumentation before merge as a useful result.

RunDiff should evaluate whether `insufficient_evidence` / `missing_instrumentation` deserves a first-class finding family alongside behavioral regressions.

Candidate examples:

- scenario exercises a path but no HTTP evidence is available;
- a database-sensitive change has no SQL evidence source;
- an expected signal cannot be measured;
- provenance is too weak to compare baseline and candidate reliably;
- candidate introduces an effect outside the currently instrumented boundary.

This should not automatically mean BLOCK in every policy. It should be explicit evidence about assurance quality.

## Security Reviewer adjacency

Cursor's Security Reviewer is adjacent rather than equivalent to RunDiff. It performs code-aware security review across authentication, authorization, injection, secrets, unsafe deserialization, dependency vulnerabilities, and infrastructure/config issues.

The RunDiff-specific opportunity is differential runtime security evidence, for example:

~~~text
baseline outbound hosts:
  api.stripe.com

candidate outbound hosts:
  api.stripe.com
  unexpected.example.com
~~~

Possible future sensors include:

- new outbound destinations;
- new filesystem writes;
- changed privilege use;
- unexpected secret access attempts;
- changed network or process behavior.

This is a future investigation, not an accepted scope expansion.

## Relationship to existing RFCs

- RFC 0005 defines differential mutation evidence.
- RFC 0006 defines portable execution and multi-source evidence.
- RFC 0010 defines behavioral analysis finding taxonomy.
- RFC 0011 defines the control-plane/executor protocol boundary and durable causal lineage.
- This RFC adds a possible higher-level artifact that states what evidence and behavioral expectations a specific change requires.

## Possible future spike

Before promoting Verification Plan into the core domain:

1. Generate a plan from several real PR diffs.
2. Compare agent-generated expectations with human-authored expectations.
3. Execute applicable checks through existing RunDiff baseline/candidate machinery.
4. Measure false positives, omitted risks, and instrumentation-gap usefulness.
5. Decide which fields must be deterministic contracts versus advisory annotations.
6. Evaluate whether an external contract such as AuditSpec should represent some or all of the plan.
7. Test portability into a post-deploy consumer such as Operational without coupling RunDiff to that product.

## Non-goals

This RFC does not:

- make Cursor a dependency;
- change the current RunDiff execution architecture;
- turn RunDiff into a production observability platform;
- make agent-generated plans authoritative by default;
- adopt a new schema;
- require Operational, AuditSpec, or ETLayer;
- add Security Reviewer-style static analysis to current scope.

## Consolidation rule

Do not rewrite canonical RunDiff architecture or roadmap solely because this RFC exists.

During a later weekly/monthly consolidation, compare this research note against:

- production and demo evidence;
- current RunDiff contracts;
- other accumulated RFCs;
- Operational and AuditSpec research;
- concrete customer requirements;
- newer market signals.

Only promoted conclusions become canonical product truth.
