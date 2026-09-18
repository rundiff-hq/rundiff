# RFC 0004: Compute and executor strategy

## Status

Draft.

## Context

Plywo compares software behavior between a baseline and one or more candidates. The product therefore needs real execution compute, not only static repository analysis.

The current RunDiff repository uses GitHub Actions heavily for its own CI and dogfood proofs. That must not be confused with the desired hosted customer architecture. The production runtime already separates the GitHub-facing control plane from an isolated executor service through portable Request v1 / Result v1 contracts.

This RFC records the product and infrastructure implications of that split.

## Decision summary

1. Hosted Plywo should use Plywo-managed compute by default.
2. Installing Plywo should not require customers to double their GitHub Actions usage.
3. GitHub Actions, Blacksmith-backed Actions, and customer self-hosted infrastructure should remain possible executor providers, especially for BYOC/enterprise use cases.
4. Plywo must not implement a naive `CI x 2` or `CI x 3` execution model.
5. Only checks whose meaning depends on behavioral comparison should run A/B by default.
6. Existing candidate CI evidence should be reused when identity and evidence contracts make reuse safe.
7. Baseline execution should be reusable where scenario, environment, dependency and commit identity permit it.
8. Deep eBPF/kernel evidence should be treated as a host-capability feature and should not depend on generic hosted runner behavior.
9. Deterministic evidence and behavioral diff remain the correctness path. Any LLM explanation belongs downstream and is optional.
10. Pricing must be based on measured unit economics rather than transient public provider price snapshots.

## Two different compute planes

### Plywo repository CI

Today `rundiff-hq/rundiff` runs tests, linting, security checks, dogfood flows and remote-executor topology proofs on GitHub Actions. This validates Plywo itself.

That does not define the customer product contract.

### Customer Behavioral Review

The intended hosted flow is:

```text
GitHub
  -> Plywo control plane
       -> durable execution
       -> execution provider
            -> exact baseline/candidate subjects
            -> scenario execution
            -> evidence capture
            -> behavioral diff inputs
       <- Result v1
  -> finalization
  -> GitHub Check + PR feedback
```

The control plane should not execute customer repositories locally in production.

## Why not make customer GitHub Actions the default

A simple integration could install a workflow into the customer repository and execute both baseline and candidate on GitHub-hosted runners. That is attractive operationally but creates poor default economics and product coupling.

If a customer already executes the candidate in normal CI, a naive Plywo workflow can produce:

```text
existing candidate CI      = 1x
Plywo baseline             = +1x
Plywo candidate again      = +1x
--------------------------------
possible total             = 3x
```

Even a better implementation that reuses the candidate but adds a baseline can approximately double the relevant duplicated runtime:

```text
existing candidate CI      = 1x
Plywo baseline             = +1x
--------------------------------
comparison-related total   = 2x
```

The actual customer invoice depends on included Actions minutes, runner class and plan, but the architectural point remains: Plywo should not make increased customer CI spend a prerequisite for adoption.

## Default hosted topology

The preferred hosted model is:

```text
                   +---------------------+
GitHub webhook --->| Plywo control plane |
                   | Rails + PostgreSQL  |
                   +----------+----------+
                              |
                              | Request v1
                              v
                   +---------------------+
                   | execution scheduler |
                   +----------+----------+
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
         executor A      executor B      executor C
         disposable      disposable      disposable
              |               |               |
              +-------> evidence/results <----+
                              |
                              v
                           R2/S3
```

Customer code runs in an isolated executor environment owned by the selected execution provider. For `plywo_cloud`, Plywo owns that compute and recovers the cost through product pricing.

The product onboarding remains:

```text
Install GitHub App
add minimal plywo.yml
open/update PR
```

No customer runner configuration should be required for the default path.

## Execution-provider abstraction

The existing Request v1 / Result v1 boundary should remain infrastructure-neutral.

Future provider families may include:

```text
plywo_cloud
  -> Plywo-managed VM/container pool

github_actions
  -> customer GitHub-hosted or configured Actions runner

blacksmith
  -> GitHub Actions workflow backed by Blacksmith runners

self_hosted / BYOC
  -> customer-controlled runner, VM pool, private executor or network
```

Provider selection should normally be account/organization policy. The minimal repository configuration should not need to mention infrastructure when using the default provider.

Illustrative future configuration only:

```yaml
executor:
  provider: plywo_cloud
```

This is not yet a committed configuration contract.

## Blacksmith

Blacksmith is a valid future execution provider or BYOC path because it is compatible with GitHub Actions and can provide faster/cheaper runner infrastructure than standard GitHub-hosted runners for some workloads.

It should not become the architectural foundation of hosted Plywo. Otherwise the stack becomes:

```text
Plywo scheduler
  -> GitHub Actions scheduler
       -> Blacksmith scheduler
            -> VM
```

instead of the simpler hosted path:

```text
Plywo scheduler
  -> executor
```

Blacksmith remains valuable for customers who already use it or explicitly want their Behavioral Reviews to run inside their CI infrastructure.

## GitHub self-hosted runners

Customer or Plywo-owned self-hosted runners are also viable execution targets. They avoid GitHub-hosted runner-minute billing and preserve familiar Actions orchestration.

However, Plywo already has its own durable execution lifecycle, cancellation, leases, Request v1 and Result v1. Therefore GitHub Actions is not required as an intermediary for Plywo-managed execution.

A direct executor is simpler when Plywo owns the compute.

## Do not run everything A/B

Plywo is not `CI x 2`.

Checks should be classified by semantics.

### Candidate-only by default

Examples:

- lint
- formatting
- static type checks
- most static security analysis
- other checks where baseline execution adds no useful behavioral comparison

Running RuboCop or an equivalent linter on both baseline and candidate usually wastes compute because the baseline result does not explain runtime behavior.

### A/B by default when relevant

Examples:

- HTTP/API scenarios
- browser/user flows
- selected tests whose execution evidence is useful
- SQL/query behavior
- background jobs
- external side effects
- latency
- memory/resource behavior
- network behavior
- runtime traces/profiles
- file/process behavior

The execution planner should make this classification explicit.

## Candidate result reuse

If the customer already executed an equivalent candidate check in CI, Plywo should eventually be able to consume/import that evidence rather than rerunning it.

Reuse is allowed only when identity is strong enough, including at least:

- exact candidate SHA
- exact scenario/test identity
- compatible runtime/environment profile
- compatible instrumentation/evidence contract
- trustworthy provenance

A green exit code alone is insufficient evidence for behavioral comparison.

## Baseline reuse

A baseline can often be reused across multiple candidates or PR updates. This is especially important for RFC 0003, where one baseline may be compared with many candidates.

Potential cache identity includes:

```text
baseline commit SHA
scenario identity
subject environment
runtime/toolchain identity
instrumentation profile
fixture/database identity
relevant secrets/emulator profile
```

Invalidation must be explicit. Plywo must never silently reuse a baseline captured under an incompatible environment.

## Runtime evidence and eBPF

Many useful evidence classes are suitable for ordinary Linux CI runners:

- Rails notifications
- SQL/query capture
- ActiveJob events
- outbound HTTP side effects
- OTEL traces
- process RSS/CPU samples
- GC/runtime metrics
- Playwright/browser artifacts

Deeper evidence may require a controlled host:

- eBPF probes
- syscalls
- socket/network-flow tracing
- file-system I/O tracing
- scheduler/kernel latency
- low-level container/process profiling

Generic GitHub-hosted or third-party runners may change kernel versions, capabilities, sandbox policies or privileges. Plywo should therefore capability-detect these features and record evidence provenance rather than assume that all providers support the same low-level instrumentation.

Deep runtime evidence is a strong reason to maintain a Plywo-controlled executor option.

## Isolation model

For managed execution, the target is a disposable customer workspace with strong tenant separation.

Conceptually:

```text
one execution
  -> acquire isolated environment
  -> clone exact repository capability
  -> prepare baseline/candidate
  -> execute scenarios
  -> upload normalized evidence/artifacts
  -> return Result v1
  -> destroy/clean environment
```

The exact mechanism may evolve from containers/process isolation to VMs or microVMs. The provider abstraction should not expose that mechanism to the portable behavioral contract.

The executor must not receive the GitHub App private key or webhook secret. Repository access remains short-lived, repository-scoped and read-only where possible.

## Cost model

The important distinction is:

```text
customer GitHub bill
!=
Plywo infrastructure cost
```

For hosted `plywo_cloud`, the customer should normally pay a Plywo subscription/usage price while Plywo pays executor compute.

The current working hypothesis is that many Behavioral Reviews will have infrastructure costs measured in cents, while heavy browser/runtime/profiling workloads may cost materially more. This is not yet a pricing fact.

Real cost depends on:

- repository clone/bootstrap
- dependency caching
- baseline reuse
- candidate-result reuse
- database preparation
- scenario count and duration
- browser usage
- CPU/RAM class
- instrumentation depth
- evidence/artifact size
- retries/failures
- idle capacity and scheduling model

Before commercial pricing is finalized, Plywo must benchmark representative repositories across multiple providers and collect per-execution usage telemetry.

## Provider price snapshots are not architecture

Public prices for GitHub-hosted runners, Blacksmith, Hetzner or any other cloud are transient. They may be useful to choose an initial implementation, but must not become durable assumptions in product contracts.

A cheap general-purpose VM provider is an attractive first `plywo_cloud` prototype because raw VM economics can be much lower than per-minute hosted CI. Hetzner-class infrastructure is a candidate for benchmarking, not a permanent architectural dependency.

## Usage metering

Plywo should record operational usage metadata outside the portable behavioral result contract:

- provider
- runner/machine class
- total wall time
- bootstrap time
- baseline time
- candidate time
- comparison/finalization time
- retries
- artifact/evidence bytes
- network bytes when available
- cache hits/misses
- baseline reuse
- imported candidate evidence
- provider-reported or estimated cost

Metering must never persist repository capabilities, credentials or customer secrets.

This data should answer:

```text
cost per Behavioral Review
cost per repository/customer
cost by evidence profile
gross margin by product plan
compute avoided through reuse
```

## Commercial model

The hosted product should not simply pass runner-minute cost through to customers.

A likely product shape is:

```text
Plywo plan
  -> included Behavioral Reviews / usage allowance
  -> managed compute included by default
  -> optional higher-cost/deeper evidence tiers
  -> optional BYOC for enterprise
```

Exact plan prices are explicitly outside this RFC and should be chosen after benchmark and usage data exist.

## LLM boundary

The core architecture remains:

```text
instrumentation
  -> structured evidence
  -> deterministic behavioral diff
  -> policy
  -> optional LLM explanation
  -> human/agent-facing review
```

An LLM must not be required to decide whether deterministic evidence changed. This keeps correctness, cost and reproducibility under control.

## Consequences

### Positive

- default onboarding does not force higher customer GitHub Actions spend
- hosted unit economics remain under Plywo's control
- stronger tenant isolation is possible
- deep runtime/eBPF capabilities can be supported on controlled hosts
- enterprise customers can still bring compute
- provider competition remains possible
- baseline/candidate reuse can materially reduce compute

### Costs

- Plywo must operate execution infrastructure
- sandboxing and tenant isolation become first-class responsibilities
- capacity planning and queueing become product concerns
- usage metering and cleanup guarantees are required
- BYOC providers add capability/provenance complexity

## Open questions

1. What is the first `plywo_cloud` isolation primitive: container, VM, microVM, or warm worker pool?
2. What bootstrap contract is safe enough for arbitrary customer Rails applications?
3. What exact identity is required for importing existing candidate CI evidence?
4. What baseline cache invalidation contract is sufficient?
5. Which eBPF features are worth making a hosted differentiator?
6. Should provider choice live only in account policy or also in `plywo.yml`?
7. What usage dimensions should drive paid plans?
8. What minimum runner capability contract should every provider expose?

## Related work

- RFC 0002: Runner adapter contract
- RFC 0003: One baseline, many candidates
- `docs/production-runtime.md`
- `docs/executor.md`
- #76 managed executor strategy
- #77 provider benchmarks and cost model
- #78 candidate reuse and A/B execution policy
- #79 eBPF/runtime evidence boundary
- #80 usage metering
- #81 customer BYOC providers
- #82 managed disposable executor prototype
- #83 executor-provider configuration
- #84 commercial pricing assumptions
- #85 RFC tracking issue
