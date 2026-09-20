# RFC 0008: Ownership-aware finding routing

## Status

Accepted direction. Implementation is incremental.

## Context

A RunDiff finding should reach the people and systems that own the affected behavior.

Today, developer tools often broadcast every failure to one generic channel or rely on whoever happens to open the pull request. That does not scale well when repositories contain many teams, when AI agents generate large volumes of candidate changes, or when a finding belongs to a domain different from the PR author.

RunDiff already has evidence, source attribution, scenario identity, GitHub context, and machine-readable findings. The next layer is routing.

This RFC defines ownership resolution, CODEOWNERS integration, routing policy, notification and action adapters, severity/confidence-aware delivery, and the distinction between ownership and causality.

## Decision summary

1. RunDiff introduces an Ownership Resolver and Routing Engine after Behavioral Diff.
2. CODEOWNERS is the preferred first ownership source because it already exists in many repositories and is reviewable through Git.
3. Ownership is not causality. A CODEOWNERS match means a team owns an affected path; it does not prove that team caused a regression.
4. Scenario ownership and source-code ownership are separate signals and may identify different teams.
5. Routing decisions must be explainable.
6. GitHub remains the primary review surface for PR-triggered findings.
7. External channels are policy-driven, not automatic broadcast.
8. Potential notification/action adapters include Slack, Microsoft Teams, Discord, Telegram, email, generic webhooks, issue trackers, incident systems, and future agents.
9. Channel credentials, webhook secrets, and private destination identifiers do not belong in rundiff.yml.
10. Repository configuration may declare routing intent and stable team aliases; the control plane maps aliases to private destinations.
11. Infrastructure failures route to CI/RunDiff operational ownership, not automatically to application CODEOWNERS.
12. High-confidence blocking findings may route more broadly than informational or inconclusive findings.
13. Agent routing is a future first-class use case: a finding may be delivered to both humans and repair/investigation agents.

## Architecture

~~~text
Execution
   |
   v
Evidence
   |
   v
Behavioral Diff
   |
   v
Finding
   |
   +--> Ownership Resolver
   |       |
   |       v
   |   Ownership Set
   |
   +--> Routing Policy
           |
           v
       Delivery Plan
           |
     +-----+------+------+------+------+
     |            |             |             |
     v            v             v             v
   GitHub       Slack         Email       Webhook/Agent
~~~

The Routing Engine does not change the behavioral decision. It decides where an already-classified finding should go.

## Ownership sources

Ownership is resolved from one or more sources.

### CODEOWNERS

Example:

~~~text
/app/payments/**      @acme/payments
/app/search/**        @acme/search
/app/checkout/**      @acme/checkout
~~~

RunDiff may resolve a trusted source location or changed file to one or more CODEOWNERS entries.

CODEOWNERS is useful because it is repository-owned, reviewable, already understood by GitHub teams, branch-aware, and available without inventing a parallel ownership database.

### Scenario ownership

A behavioral scenario can span multiple files and teams.

A future rundiff.yml shape may allow:

~~~yaml
ownership:
  scenarios:
    checkout:
      - payments
      - checkout
~~~

The exact schema is not yet committed.

Scenario ownership answers:

> Who owns this customer/business behavior?

Path ownership answers:

> Who owns this source area?

Both can be useful.

### Explicit RunDiff ownership mapping

RunDiff may support stable aliases:

~~~yaml
ownership:
  aliases:
    payments:
      github:
        - "@acme/payments"
~~~

Private notification destinations should not live in the repository file.

### Future ownership sources

Potential future sources include Backstage, service catalogs, repository/service manifests, GitHub teams, Kubernetes/service labels, internal ownership APIs, and organization directory integrations.

Do not implement all sources speculatively. CODEOWNERS plus explicit scenario ownership is the preferred first slice.

## Ownership is not causality

Suppose a PR changes:

~~~text
app/services/checkout.rb
~~~

and CODEOWNERS maps that path to:

~~~text
@acme/payments
~~~

RunDiff may say:

> The changed source is owned by @acme/payments.

It must not say:

> @acme/payments caused this regression.

Likewise, runtime evidence may point at a source location without proving that line is the root cause.

The Routing Engine operates on ownership and affected behavior, not blame.

This distinction is especially important when a changed configuration triggers unchanged runtime code, an upstream change increases calls to a downstream owned service, a scenario spans multiple ownership domains, or source attribution is ambiguous.

## Ownership reasons

A resolved owner should carry a reason.

Example:

~~~text
@acme/api
  reason: owns changed source

@acme/payments
  reason: owns affected scenario
~~~

A future normalized structure may include:

~~~json
{
  "owner": "payments",
  "source": "codeowners",
  "reason": "owns_changed_path",
  "path": "app/services/payments/charge.rb"
}
~~~

The exact schema is future work.

## Routing policy

Routing is based on finding type, decision, severity, confidence, ownership, and execution outcome.

Illustrative policy:

### Informational

~~~text
GitHub only
~~~

### Warning / review

~~~text
GitHub
+ optional team channel
~~~

### Blocking behavioral regression

~~~text
GitHub
+ primary owner channel
+ optional email/webhook
~~~

### Performance regression

Only escalate externally when confidence is sufficient.

Example:

~~~text
BLOCK + Performance + HIGH confidence
  -> GitHub
  -> owning team channel
~~~

But:

~~~text
Performance conclusion: INCONCLUSIVE
  -> GitHub only
~~~

### Infrastructure failure

Infrastructure failures are not application regressions.

Default routing should be:

~~~text
INFRA_FAILURE
  -> GitHub execution surface
  -> CI / RunDiff operations owner
~~~

not:

~~~text
INFRA_FAILURE
  -> application CODEOWNERS
~~~

unless organization policy explicitly requests it.

## Primary and interested owners

A finding may have more than one ownership relationship.

Example:

~~~text
SQL regression

changed source owner:
  @acme/api

affected scenario owner:
  @acme/payments
~~~

RunDiff may classify:

~~~text
Primary
  @acme/api

Interested
  @acme/payments
~~~

The initial version can remain simpler and notify all resolved owners. The data model should not assume there is always exactly one owner.

## Delivery adapters

Potential adapters:

~~~text
GitHub
Slack
Microsoft Teams
Discord
Telegram
Email
Generic Webhook
Linear
Jira
PagerDuty / incident system
Agent / MCP / API
~~~

The generic webhook is strategically important because it lets organizations integrate internal systems without waiting for a dedicated first-party adapter.

## Repository policy versus private destination mapping

Repository-owned config may describe semantic routing policy.

Example:

~~~yaml
routing:
  defaults:
    block:
      - github
      - team_channel

    warning:
      - github

  ownership:
    source:
      - codeowners
      - scenario
~~~

The repository should not contain Slack webhook URLs, Telegram bot tokens, email service credentials, Discord webhook secrets, or internal channel IDs where organization policy treats them as private.

Instead:

~~~text
repository alias
    payments
       |
       v
RunDiff account mapping
       |
       +--> Slack C012345
       +--> email payments@example.com
       +--> webhook integration id 42
~~~

This keeps repo config portable and private integration state in the control plane.

## Control-panel UX

Example:

~~~text
Ownership & Routing

Payments

GitHub
  @acme/payments

Slack
  #payments-alerts

Email
  payments@example.com

Notify when
  [x] RunDiff blocks a change
  [x] High-confidence performance regression
  [ ] Warnings
  [ ] Infrastructure failures
~~~

Scenario-level UI:

~~~text
Checkout

Owners
  payments
  checkout

Routing
  BLOCK   -> team channel
  REVIEW  -> GitHub only
~~~

## GitHub behavior

GitHub remains the primary PR surface.

A finding may render:

~~~text
BLOCK - DATABASE_QUERY_REGRESSION

17 -> 31 SQL queries (+82%)

Scenario
  checkout.create-order

Ownership
  @acme/payments
  reason: owns affected checkout source

Evidence
  ...
~~~

CODEOWNERS can continue to drive GitHub-native review requests independently of RunDiff external routing.

RunDiff should not create redundant @mentions when GitHub has already routed the PR appropriately unless policy explicitly asks for them.

## Routing and agent workflows

A future finding can route to humans and agents simultaneously.

Example:

~~~text
DATABASE_QUERY_REGRESSION
confidence: HIGH

human route
  -> Slack #payments-alerts

agent route
  -> machine-readable finding
  -> repair agent
  -> candidate patch
  -> RunDiff re-review
~~~

This extends ADR 0005: humans should receive concise presentation; agents should receive stable machine contracts.

The Routing Engine may eventually dispatch work, not only notifications.

Possible action targets include repair agents, investigation agents, Linear/Jira issues, incident workflows, benchmark confirmation runs, and controlled Performance re-runs.

Automated actions must remain policy-controlled and auditable.

## Rate limiting and notification fatigue

Routing must avoid turning RunDiff into a spam generator.

Potential controls:

- one durable notification updated per finding/review;
- suppress repeated identical findings across superseded candidates;
- aggregate findings by team;
- severity thresholds;
- confidence thresholds;
- per-channel quiet policies;
- deduplicate when GitHub already notified the same team;
- do not notify on stale execution results.

This is especially important for high-volume AI-generated candidate workflows.

## Security and privacy

Ownership metadata and destination mappings are customer data.

RunDiff should restrict destination configuration to authorized organization members, avoid logging tokens/webhook URLs, encrypt integration secrets, preserve audit history for routing changes, keep repository aliases separate from secret destination configuration, and honor repository/account authorization when displaying ownership data.

## Implementation sequence

### Phase 1

- parse CODEOWNERS for trusted affected paths;
- introduce Ownership Resolver;
- add ownership reasons to findings/review metadata;
- render owners in RunDiff UI and GitHub review;
- no external notifications required yet.

### Phase 2

- add stable team aliases;
- add Slack and generic webhook adapters;
- add severity/confidence routing policy;
- separate application findings from INFRA_FAILURE routing.

### Phase 3

- add scenario ownership;
- add email/Teams/Discord/Telegram as customer demand requires;
- add organization routing UI and audit history;
- aggregate/deduplicate notifications.

### Phase 4

- service catalog integrations;
- agent/action routing;
- automatic investigation/repair workflows under explicit policy.

## Consequences

### Positive

- findings reach relevant teams;
- CODEOWNERS gains value beyond review assignment;
- routing remains explainable;
- large monorepos become more manageable;
- external notifications can be selective;
- infrastructure failures stop spamming product teams;
- agent workflows fit the same routing architecture.

### Costs

- ownership can be ambiguous;
- CODEOWNERS may be stale or broad;
- scenario ownership adds another maintained concept;
- external integrations add secret management;
- notification deduplication becomes necessary;
- routing policy requires authorization and audit.

## Non-goals

This RFC does not claim ownership proves causality, replace GitHub CODEOWNERS, require Slack or any specific chat platform, store notification secrets in rundiff.yml, define final team/organization model, automatically page teams for every finding, or let routing override Behavioral Diff or merge policy.

## Open questions

1. What path/source confidence is required before resolving CODEOWNERS?
2. Should changed-file ownership and runtime-source ownership receive different weights?
3. How are multiple CODEOWNERS entries merged?
4. What is the first scenario-ownership schema?
5. When should RunDiff @mention GitHub teams versus rely on native review requests?
6. What notification rate limits are appropriate for agent-generated candidate volume?
7. How should routing behave across monorepo subprojects with separate policy?
8. Which generic webhook signing scheme should be used?
9. How should routing changes be audited and versioned?
10. What automated actions are safe enough for v1 agent routing?

## Related work

- ADR 0005: Separate human and agent contracts
- RFC 0001: Agent-readable result contract
- RFC 0004: Execution planning, compute, placement, and evidence strategy
- RFC 0007: Repository configuration, review workload, and source-code boundary
- docs/github.md
