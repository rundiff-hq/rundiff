# RunDiff product vision

> Snapshot: 2026-09-21
>
> This document captures the canonical product direction and brand/messaging snapshot. It is intentionally broader than the current implementation. For implementation truth, production proof status, and current customer contract, see `docs/current-state.md`.

## Brand

Canonical product spelling:

- Product: **RunDiff**
- CLI / binary / package: `rundiff`
- Wordmark may use: **RUNDIFF**
- Avoid: `RunDif`, `Rundiff`, or inconsistent casing in product copy

The name should be understood primarily as **Run + Diff**.

For a developer audience, `diff` is already a strong primitive: compare two states and show what changed. RunDiff extends that primitive from source code into executed behavior.

The useful wordplay is:

- **run diff** - execute a comparison;
- **runtime diff** - compare what changed in the running system;
- **run different** - an informal secondary association, useful as wordplay but not the canonical etymology.

## Product idea

### Current wedge

RunDiff is a **pre-merge behavioral diff for pull requests**.

It executes a baseline and candidate under the same scenario, collects runtime evidence, compares the two executions, and surfaces meaningful behavioral changes before the pull request is merged.

The current controlled variable is primarily **code**:

```text
same runtime
same scenario
different code
    |
    v
what changed in behavior?
```

Examples of evidence include latency, SQL behavior, jobs, side effects, memory, network activity, traces, logs, and business-relevant events.

The important distinction is that a green test suite does not imply unchanged behavior.

### Long-term product primitive

The durable abstraction is broader than "compare two Git commits":

```text
Execution A
Execution B
same scenario
controlled change
    |
    v
evidence
    |
    v
behavioral diff
```

A Git pull request is the first and most valuable controlled-change adapter, not the final boundary of the product.

Over time, the controlled change may be:

- code;
- configuration;
- dependency or runtime version;
- CPU or memory allocation;
- instance type;
- storage technology or performance;
- network latency, bandwidth, packet loss, or topology;
- database placement or capacity;
- cache availability;
- third-party latency or availability;
- feature flags;
- injected failure conditions.

This enables a second major mode:

```text
same code
same scenario
different runtime
    |
    v
what changed in behavior?
```

Examples:

- Does moving from HDD to NVMe materially change request latency or DB wait time?
- Does a private network reduce latency or failure rate?
- Does doubling CPU improve throughput or simply move the bottleneck?
- What happens when database latency increases by 40 ms?
- Does a larger instance actually change user-visible or business-visible behavior?

RunDiff should compare the evidence and make the change visible. Controlled comparisons can support causal investigation, but RunDiff should not claim causal certainty when uncontrolled variables or measurement noise remain.

## Product horizons

### V1 - Code-induced runtime diff

Primary workflow:

```text
pull request
  -> baseline + candidate
  -> same scenario
  -> runtime evidence
  -> behavioral diff
  -> GitHub Behavioral Review
  -> human/automation decision before merge
```

Primary audience: developers and engineering teams reviewing changes in GitHub.

Primary promise: **know what behavior changed before merge**.

### V2 - Runtime-induced behavioral diff

Keep code and scenario fixed while changing a runtime condition or infrastructure component.

Examples include CPU, memory, storage, networking, database placement, dependency versions, and controlled degradation.

Primary promise: **change the runtime and measure what it actually changes**.

### Later - Controlled execution experiments

RunDiff can evolve into a controlled runtime experimentation platform where a user or agent changes one intentional variable, reruns the same workload, compares evidence, and investigates the effect.

This direction must not expand V1 scope prematurely. The first product still wins or loses on a simple GitHub pull-request workflow.

## Messaging snapshot v1

The messaging has different jobs. Do not use one sentence everywhere.

### Brand tagline

**Run it. Diff it.**

Use for brand expression, merchandise, stickers, conference material, and selective social/visual surfaces.

### Campaign line

**Observability tells you after deploy. RunDiff tells you before merge.**

Use for campaigns, launch material, conference copy, social graphics, and as a supporting line on the website.

This is positioning language, not the literal definition of all observability workflows.

### Website hero

Headline:

**Know what changed before you merge.**

Subheadline:

**RunDiff runs your baseline and candidate through the same scenario, compares their runtime behavior, and surfaces meaningful changes directly in your pull request.**

Primary CTA:

**Run your first diff**

Secondary CTA:

**See a sample diff**

Supporting brand line:

**You diff your code. Now diff what it does.**

### GitHub organization description

**Pre-merge behavioral diffing for pull requests.**

Keep the GitHub organization description descriptive rather than campaign-heavy.

### GitHub README

Lead with a memorable hook, then immediately explain the category:

**Tests passed. Behavior changed.**

**Pre-merge behavioral diffing for pull requests.**

README copy should transition quickly from positioning into the runnable product, onboarding contract, and example Behavioral Review.

### Repository / README descriptor

**RunDiff compares the runtime behavior of a baseline and candidate and surfaces meaningful behavioral changes before merge.**

The README may additionally use the campaign line, but should quickly transition into concrete product behavior and a runnable example.

### X / Twitter bio

**Run the change. Diff the behavior. See meaningful runtime changes before merge.**

Social copy can be more expressive than repository documentation while keeping the same core idea.

### LinkedIn

**Pre-merge behavioral diffing for software teams. Run the baseline and candidate, compare runtime behavior, and see meaningful changes before merge.**

Use the more explicit category language here because company pages are often encountered without prior product context.

### Facebook

**See what your code actually changes before it reaches main. RunDiff compares baseline and candidate runtime behavior directly in the pull-request workflow.**

Treat Facebook as a secondary distribution surface, not a source of canonical product wording.

### Product Hunt

Headline:

**Behavioral diffs for pull requests.**

Supporting line:

**You diff your code. Now diff what it does.**

Product Hunt copy should lead with the category and demo outcome rather than infrastructure details.

### Docs homepage

**RunDiff compares executions and explains meaningful behavioral changes before merge.**

Docs should optimize for precision and navigation, not campaign language.

### YouTube

Channel/product descriptor:

**Runtime behavioral diffs before merge.**

Video titles and descriptions should prefer explicit search terms such as GitHub pull requests, runtime behavior, regressions, behavioral diff, and pre-merge validation over abstract brand language.

### Merchandise / stickers / conference

Preferred short line:

**Run it. Diff it.**

Alternative conversation-starter:

**You diff your code. Now diff what it does.**

Do not put a product-action CTA such as "Run your first diff" on merchandise unless the design explicitly points to an onboarding URL or QR code.

## CTA model

A tagline, headline, descriptor, and CTA are not interchangeable:

- **Tagline** - memorable expression of the brand: "Run it. Diff it."
- **Campaign line** - contrast or market positioning: "Observability tells you after deploy. RunDiff tells you before merge."
- **Hero headline** - immediate value proposition: "Know what changed before you merge."
- **Descriptor** - literal category/product explanation: "Pre-merge behavioral diffing for pull requests."
- **CTA** - requested next action: "Run your first diff."

For the first public product, the CTA should optimize for reaching a real Behavioral Review, not for generic account creation.

### CTA lifecycle

Use CTA wording that matches the actual product state:

- **Pre-launch / proof stage** - prefer **See a sample diff** or **View a Behavioral Review** when an external user cannot yet complete the full flow reliably.
- **Public usable product** - use **Run your first diff** as the primary landing CTA.
- **Onboarding** - use **Install RunDiff on GitHub** because the user has already entered the setup funnel.
- **Post-install** - guide the user toward the next concrete action, such as adding `rundiff.yml` or opening a pull request.

Do not use **Sign up** as the main CTA while a more product-specific next action is available.

### Surface matrix

The canonical message should stay stable while the expression changes by surface:

| Surface | Primary job | Preferred wording |
| --- | --- | --- |
| Website | Explain value and start product flow | **Know what changed before you merge.** |
| GitHub Organization | Define category | **Pre-merge behavioral diffing for pull requests.** |
| GitHub README | Hook, then prove | **Tests passed. Behavior changed.** + category descriptor |
| X / Twitter | Memorable developer language | **Run the change. Diff the behavior.** |
| LinkedIn | Explain product to engineering organizations | Explicit category + workflow |
| Facebook | Secondary awareness | Plain-language value statement |
| Product Hunt | Category + novelty | **Behavioral diffs for pull requests.** |
| YouTube | Search/discovery | **Runtime behavioral diffs before merge.** |
| Docs | Precision | Execution comparison + behavioral diff |
| Merchandise / stickers | Brand memory | **Run it. Diff it.** |
| Conference booth | Start a conversation | **You diff your code. Now diff what it does.** |

## Messaging guardrails

Prefer these words:

- run;
- diff;
- behavior;
- runtime;
- baseline;
- candidate;
- evidence;
- change;
- before merge;
- behavioral review.

Be careful with these words:

- regression - a change is not automatically bad;
- block - RunDiff may surface evidence without deciding every change is invalid;
- test - RunDiff is complementary to tests, not merely another test runner;
- observability - useful contrast, but RunDiff should not position observability as obsolete;
- causality - controlled comparisons can strengthen attribution, but causal certainty requires stronger experimental controls.

Avoid defining the product as merely:

- a CI wrapper;
- a performance benchmark;
- an observability backend;
- a test runner;
- a GitHub comment bot.

## One-sentence product vision

**RunDiff makes the effect of a controlled change visible by executing comparable runs, collecting evidence, and diffing behavior before that change is accepted.**
