# RunDiff Homepage Positioning - Chat Snapshot

## Status

Conversation snapshot for later comparison.

This document intentionally preserves the marketing direction and homepage example discussed in chat on 2026-09-21.

It is **not** a final product or brand decision.

The purpose is to keep the exact line of thinking available so it can later be compared with alternative homepage concepts, messaging, and information architecture.

---

## Core positioning

Do not position RunDiff primarily as a tool that "supports many programming languages."

The stronger abstraction is:

> RunDiff checks system behavior, not the language the system is written in.

The homepage should communicate that RunDiff works across languages and runtimes, but language support should be supporting proof, not the central product definition.

A useful internal model:

~~~text
Runnable workload
      |
      v
Baseline + Candidate
      |
      v
Same scenario
      |
      v
Runtime evidence
      |
      v
Behavioral diff
~~~

Possible homepage line:

> If it runs, RunDiff can compare it.

Possible supporting section:

~~~text
Works across your stack.

Ruby  Python  Node.js  Go  Java  Rust  Containers
+ anything you can run
~~~

Important distinction:

- generic workload support;
- deeper runtime/framework instrumentation.

For example, a generic container can still be compared, while a Rails-specific sensor may produce richer SQL or framework-level evidence.

---

## What not to make prominent on the homepage

### Executor implementation language

The fact that the executor is written in Go is an implementation detail and should not be part of the primary homepage story.

Avoid:

> Powered by a Go executor

Prefer customer-facing capabilities such as:

> Isolated, reproducible execution

or:

> Run the same workload against baseline and candidate.

Go belongs in:

- architecture docs;
- engineering blog;
- GitHub README;
- technical deep dives;
- an article such as "Why we built the RunDiff executor in Go."

### Cloudflare Containers

Do not make "Runs on Cloudflare Containers" part of the main value proposition.

That makes users think about RunDiff infrastructure instead of their own problem.

Prefer a product-level execution model:

~~~text
RunDiff Control Plane

Execution Providers
├─ GitHub Actions
├─ RunDiff Cloud
├─ BYOC
└─ Self-hosted
~~~

The implementation behind RunDiff Cloud may change later without changing the marketing language.

---

## What should be visible on the homepage

### GitHub

GitHub Actions / GitHub integration is worth showing because it is directly visible to users.

The message is not "our executor runs on GitHub Actions."

The message is:

~~~text
Pull Request
    |
    v
RunDiff
    |
    v
Behavioral Diff
    |
    v
GitHub Check
~~~

Possible copy:

> Built for pull requests.

> RunDiff compares your baseline and candidate and reports behavioral changes directly on the PR.

---

## Homepage example preserved from chat

The following is the concrete homepage example that was discussed and should be preserved for later comparison.

~~~text
RunDiff

Know what changed before you merge.

Compare baseline and candidate under the same scenario.
See behavioral changes before they reach production.

[ Get started ] [ See an example ]

────────────────────────────

CODE DIFF
14 files changed

BEHAVIORAL DIFF

SQL queries       17 → 31     +82%
HTTP calls         4 → 7      +75%
p95 latency      181 → 294ms  +62%
Memory            42 → 44MB    +5%

Decision: BLOCK

────────────────────────────

Works across your stack

Ruby  Python  Node.js  Go  Java  Rust  Containers
+ anything you can run

────────────────────────────

Catch changes tests don't describe.

Database
Networking
CPU
Memory
API
Concurrency
Queues

────────────────────────────

Built for pull requests.

GitHub → RunDiff → Behavioral Diff → Check

────────────────────────────

Learn what runtime regressions look like.

N+1 Queries
Retry Storms
API Amplification
Missing Indexes
Sequential I/O
O(n²) Regressions

[ Explore the Runtime Regression Library ]
~~~

---

## Strong messaging candidates from the discussion

Primary conceptual statement:

> Git tells you what code changed. RunDiff tells you what behavior changed.

Alternative compact product idea:

> Know what changed before you merge.

Supporting runtime-neutral statement:

> If it runs, RunDiff can compare it.

The homepage should avoid making programming languages, Go, Cloudflare, or any one execution provider the product category.

---

## Why this direction matters

This positioning keeps the product language valid as RunDiff expands across:

- Ruby / Rails;
- Python;
- Node.js;
- Go;
- Java;
- Rust;
- arbitrary processes;
- containers;
- future runtime environments.

The product category remains behavioral comparison before deployment rather than language-specific instrumentation.

---

## Relationship to the Runtime Regression Library

The homepage example links naturally to the Runtime Regression Library.

The library is not just a marketing blog. It can become the human explanation layer for future Findings and Diagnoses.

Example future product path:

~~~text
Finding
  database.query.count.regression

Evidence
  17 -> 31 SQL queries
  +82.4%

Diagnosis
  possible N+1 query

Learn more
  Runtime Regression Library / N+1 Queries
~~~

This creates a consistent loop between:

- homepage messaging;
- educational content;
- RunDiff rules;
- findings;
- diagnoses;
- PR review UX.

---

## Comparison note

When revisiting homepage positioning, compare new proposals against this snapshot rather than silently replacing it.

Questions to compare:

1. Does the new version communicate behavioral diff faster?
2. Does it remain runtime- and language-neutral?
3. Does it show GitHub as a user-facing integration rather than infrastructure?
4. Does it avoid overexposing Go or Cloudflare as implementation details?
5. Does the behavioral-diff example still feel concrete and memorable?
6. Does the Runtime Regression Library still connect naturally to the product?
