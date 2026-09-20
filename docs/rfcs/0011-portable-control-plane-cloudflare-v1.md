# RFC 0011: Portable Control Plane and Cloudflare-native production v1

## Status

Accepted direction. First implementation is incremental.

## Context

RunDiff's existing Rails application proved the hard product semantics:

- GitHub App identity and webhook handling;
- durable execution state;
- exact base/head identity;
- stale guards and supersede behavior;
- leases and finalization fencing;
- portable Executor Request/Result;
- behavioral comparison and GitHub publication.

Those semantics are the valuable part.

Rails, PostgreSQL, Solid Queue, Puma, and a VM are implementation choices, not the permanent definition of the RunDiff Control Plane.

For the first internet-facing production proof, RunDiff should minimize fixed infrastructure, operational surface area, and idle cost while preserving an escape hatch to a conventional Rails/PostgreSQL or other deployment later.

## Core decision

Treat the Control Plane as a set of domain responsibilities behind explicit ports.

~~~text
Git provider / user
        |
        v
RunDiff Control Plane
        |
        +--> Review Repository
        +--> Execution Repository
        +--> Workflow/Lifecycle Port
        +--> Artifact Store
        +--> Git Provider
        +--> Execution Dispatcher
        +--> Identity/Auth
        |
        v
portable domain/protocol contracts
~~~

No infrastructure adapter owns the domain model.

## Production v1 implementation

Use a Cloudflare-native implementation:

~~~text
Browser
  |
  v
React SPA
  |
  v
Hono Worker API
  |
  +--> D1
  |     product metadata/history
  |
  +--> Cloudflare Workflows
  |     durable review/execution lifecycle
  |
  +--> R2
  |     large evidence/artifacts
  |
  +--> GitHub API/App
  |
  +--> Execution Dispatcher
          |
          v
     GitHub Actions
          |
          v
     RunDiff Executor
~~~

The first implementation lives under:

~~~text
apps/control-plane-cloudflare/
~~~

The existing Rails application remains available and is not deleted.

## Technology choices

### React + Vite

Use React as the hosted Control Panel UI.

Use the Cloudflare Vite plugin so local Worker execution uses the Workers runtime rather than a Node approximation.

The UI is initially a SPA. Server-side rendering is not required for the authenticated product surface.

### Hono

Use Hono as the Worker HTTP/API framework.

Hono is an adapter/presentation layer. Domain services must not depend on Hono request/context types.

Initial routes include:

~~~text
GET  /api/health
GET  /api/ready

POST /api/github/webhooks

GET  /api/reviews/:id
GET  /api/projects/:id/reviews

POST /api/execution-bridges/github-actions/claim
POST /api/executions/:execution_id/attempts/:attempt_number/result
~~~

Exact public versioning may evolve before production publication.

### D1

Use one D1 database for production v1.

Do not start with database-per-project.

D1 stores queryable product state such as:

~~~text
users
organizations
github_installations
projects
github_deliveries

behavioral_reviews
executions
execution_attempts
findings
finding_evidence
~~~

Project-per-database or project-per-Durable-Object isolation remains a future option.

D1 is a persistence adapter, not the domain schema contract.

### Cloudflare Workflows

Use Workflows for the durable review/execution process.

Conceptually:

~~~text
create Behavioral Review
  -> persist exact identity
  -> make execution available/dispatch
  -> wait for executor result
  -> timeout -> INFRA_FAILURE
  -> validate current candidate/attempt
  -> finalize
  -> publish GitHub Check/comment
~~~

The Workflow implementation must preserve the same safety properties as the Rails implementation:

- exact base/head identity;
- one authoritative attempt;
- stale candidate rejection;
- superseded execution cannot become current;
- idempotent result handling;
- only one finalization wins;
- timeout becomes explicit execution/infrastructure state;
- GitHub publication is tied to exact candidate SHA.

A Cloudflare Workflow instance is an implementation mechanism, not the externally visible RunDiff execution identity.

### R2

Use R2 for large immutable evidence/artifacts.

D1 stores metadata and references.

Examples:

- evidence bundles;
- logs;
- traces;
- profiles;
- screenshots/video;
- future SARIF exports;
- executor artifacts.

Small v1 measurements may remain inline in D1 when that is simpler.

### Durable Objects

Do **not** require Durable Objects for VS1.

Add a Durable Object only when serialized coordination is materially useful, for example:

~~~text
ProjectCoordinator
  -> serialize GitHub PR transitions
  -> dedupe competing mutation events
  -> coordinate supersede/cancel
~~~

D1 + Workflows should prove insufficient before adding this layer.

### Queues

Do **not** require Cloudflare Queues for VS1.

Potential later uses:

- GitHub publication fan-out;
- Slack/email/webhook routing;
- analytics/event streams;
- high-volume asynchronous work.

### Containers

Cloudflare Containers are not required for the first Control Plane proof.

First external execution remains GitHub Actions.

After VS1, Cloudflare Containers are a candidate second Execution Plan using the same portable Executor Request/Result contract.

## Domain ports

The Cloudflare code should center on small ports rather than Cloudflare bindings leaking everywhere.

Illustrative TypeScript boundaries:

~~~ts
interface ReviewRepository {
  create(input: CreateReview): Promise<BehavioralReview>
  get(id: string): Promise<BehavioralReview | null>
  markSuperseded(id: string, replacementId: string): Promise<void>
}

interface ExecutionRepository {
  create(input: CreateExecution): Promise<Execution>
  claim(input: ClaimExecution): Promise<ExecutorRequest | null>
  acceptResult(input: SubmitResult): Promise<ResultAcceptance>
}

interface ReviewLifecycle {
  start(review: BehavioralReview): Promise<void>
  deliverResult(executionId: string, attempt: number, result: ExecutorResult): Promise<void>
}

interface ArtifactStore {
  put(key: string, body: ReadableStream | ArrayBuffer): Promise<ArtifactRef>
}

interface GitProvider {
  publishReview(input: PublishReview): Promise<void>
}
~~~

Names are illustrative. Keep interfaces as small as concrete use cases demand.

## GitHub Actions identity

The first bridge may retain the already-designed static bearer token while the end-to-end path is being proven.

The target production authentication is GitHub Actions OIDC:

~~~text
GitHub Actions
  -> short-lived OIDC JWT
  -> Worker verifies issuer/audience/repository/workflow claims
  -> execution claim/result accepted
~~~

Do not broaden GitHub App repository permissions to solve executor authentication.

OIDC migration must not delay the first Worker/D1/Workflow spike if a temporary secret is explicitly scoped to the proof.

## Source-code boundary

The Control Plane must not persist customer source code.

Customer source stays inside:

- GitHub-hosted/customer runner;
- future managed executor;
- customer-hosted compute.

The Control Plane receives only required metadata/evidence/artifacts.

This invariant is independent of Rails or Cloudflare.

## Portability / escape hatch

Cloudflare-specific concepts must stay behind adapters.

Desired future substitutions include:

~~~text
D1ReviewRepository
  -> PostgresReviewRepository

CloudflareWorkflowLifecycle
  -> TemporalLifecycle
  -> Rails/SolidQueue lifecycle

R2ArtifactStore
  -> S3ArtifactStore

GitHubActionsDispatcher
  -> CloudflareContainerDispatcher
  -> BuildkiteDispatcher
~~~

A future Rails Control Plane is therefore an alternate assembly of the same domain semantics, not a conceptual rewrite.

## Production proof scope

VS1 is complete when one external repository demonstrates:

~~~text
real pull_request/opened
  -> Cloudflare Worker
  -> durable D1 state
  -> Workflow instance
  -> GitHub Actions executor
  -> exact BASE/candidate Result
  -> BLOCK

same PR push/fix
  -> pull_request/synchronize
  -> previous candidate cannot finalize as current
  -> new execution
  -> ALLOW
~~~

And:

- history remains queryable from D1;
- Review Detail is visible in React;
- GitHub Check/comment is produced without manual result injection;
- executor result authentication is explicit;
- production secrets are not committed;
- actual cost is recorded.

## Non-goals for VS1

- Rails parity feature-for-feature;
- PostgreSQL;
- Solid Queue;
- Temporal;
- Durable Objects;
- Cloudflare Queues;
- Cloudflare Containers executor;
- managed Go Executor;
- Performance/Deep evidence;
- full billing;
- organization administration;
- broad notification routing;
- causal/RCA expansion.

## Migration from the Rails implementation

Do not port classes line-by-line.

Port invariants and contracts.

Use the Rails code/tests as a semantic oracle for:

- webhook dedupe;
- execution identity;
- stale/supersede logic;
- result validation;
- finalization fencing;
- GitHub publication.

Where the Cloudflare implementation differs operationally, document the equivalent invariant and test it at the domain/adapter boundary.

## Related

- ADR 0002: Execution is the core abstraction
- ADR 0005: Separate human and agent contracts
- ADR 0008: Execution Plan is the composition boundary
- ADR 0010: Source code stays in the execution boundary
- ADR 0014: GitHub identity and repository installation are separate
- ADR 0016: Control Plane is implementation-independent
- RFC 0004: Execution planning and placement
- RFC 0006: Portable execution and evidence
- RFC 0007: Repository config / Review Workload
- RFC 0010: Behavioral analysis / Finding model
