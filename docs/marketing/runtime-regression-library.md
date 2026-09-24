# RunDiff Runtime Regression Library

## Status

Working marketing and education strategy.

This document defines the editorial model for a RunDiff engineering library focused on runtime regressions, behavioral changes, system design mistakes, and failure patterns that can be detected or explained through baseline/candidate comparison.

It is intentionally connected to RFC 0010, but it does not replace the canonical RunDiff Finding model.

## Goal

RunDiff should not publish a generic company blog.

The primary content engine should teach engineers how apparently reasonable code changes produce materially different runtime behavior.

The core editorial thesis is:

> Code diff tells you what text changed. Behavioral diff tells you what the system changed.

The library should serve four purposes at the same time:

1. educate engineers;
2. create durable search and distribution content;
3. explain the classes of behavior RunDiff can detect;
4. become the human documentation layer linked from future RunDiff Findings and Diagnoses.

Over time, the desired loop is:

~~~text
engineering problem
    |
    v
educational article
    |
    v
RunDiff rule / diagnosis / evidence model
    |
    v
PR finding
    |
    v
link back to explanation
~~~

## Editorial taxonomy versus product taxonomy

RFC 0010 explicitly avoids forcing all Findings into one taxonomy tree. RunDiff Findings use orthogonal facets such as domain, quality dimension, resource, scope, change kind, and causal role.

The content library may use a simpler editorial hierarchy for navigation:

~~~text
Family
  -> Category
      -> Pattern / Problem
~~~

This hierarchy is for humans and content discovery only.

It must map back to canonical RunDiff concepts rather than becoming a second product ontology.

Example:

~~~yaml
editorial:
  family: Database
  category: Query amplification
  pattern: N+1 query

product_mapping:
  domains:
    - database
  quality_dimensions:
    - performance_efficiency
  resources:
    - database
    - io
  likely_rule_ids:
    - database.query.count.regression
  likely_diagnosis:
    - probable_n_plus_one
~~~

## Editorial families

Initial families:

- Database
- Network and API
- CPU and Algorithms
- Memory
- Async and Queues
- Concurrency
- Reliability
- Caching
- Filesystem and I/O
- Architecture and Execution Placement

These are editorial navigation groups, not canonical RunDiff facets.

## Standard article anatomy

Every article should follow roughly the same model.

### 1. Hook

Start with a concrete engineering surprise.

Examples:

- a one-line code change doubled SQL queries;
- a harmless extra API call added 400 ms to p95 latency;
- a retry policy caused more failures;
- a test suite stayed green while production behavior regressed.

### 2. Problem

Describe what changed in runtime behavior.

### 3. Family

Editorial family such as Database, Network and API, or Reliability.

### 4. Category

A narrower class such as query amplification, request amplification, contention, retry behavior, or computation placement.

### 5. Pattern

The recognizable engineering pattern, such as N+1, sequential I/O, thundering herd, missing index, or accidental O(n^2).

### 6. Why it happens

Explain the implementation decisions that create the behavior.

### 7. Evidence

Show the signals that expose it.

Examples:

- SQL query count;
- repeated query fingerprints;
- wall time;
- CPU time;
- allocations;
- memory high-water mark;
- outbound HTTP request count;
- dependency latency;
- queue wait;
- retry count;
- lock wait;
- filesystem bytes or operations.

### 8. Baseline versus candidate

Whenever possible, include a small RunDiff-style comparison.

~~~text
Baseline
SQL queries       17
wall time          182 ms
outbound HTTP        4

Candidate
SQL queries       31
wall time          294 ms
outbound HTTP        4

Behavioral change
SQL queries       +82.4%
wall time         +61.5%
~~~

### 9. Diagnosis

Explain what the evidence may mean, while distinguishing direct measurement from inferred cause.

For example:

~~~text
Finding:
database.query.count.regression

Diagnosis:
probable_n_plus_one

Detection confidence:
high - deterministic measurement

Diagnosis confidence:
medium - inferred pattern
~~~

### 10. Remediation

Explain multiple valid fixes and their tradeoffs rather than presenting one universal prescription.

### 11. Catching it before production

End with a concise RunDiff section showing how a baseline/candidate behavioral comparison can surface the problem in a pull request.

The article should remain primarily educational. RunDiff should normally occupy the final 10-20% of the article, not every section.

## First 10 articles

These should establish the library, cover several families, and make the RunDiff thesis easy to understand.

### 01. The N+1 Query: When One Line Creates 1,000 Queries

**Family:** Database  
**Category:** Query amplification  
**Pattern:** N+1 query

**Premise**

A code change can remain functionally correct while multiplying database round trips.

**Primary evidence**

- SQL query count;
- repeated query fingerprints;
- database time;
- request wall time.

**RunDiff mapping**

Likely Finding:

~~~text
database.query.count.regression
~~~

Likely Diagnosis:

~~~text
probable_n_plus_one
~~~

**Remediation themes**

- eager loading;
- joins;
- batching;
- preload strategy;
- query-shape redesign.

**Why first**

It is easy to explain, common across frameworks, and maps directly to the current canonical RunDiff demo of query count increasing from 17 to 31.

---

### 02. When Your Application Does the Database's Job

**Family:** Architecture and Execution Placement  
**Category:** Computation placement  
**Pattern:** Application-side aggregation

**Premise**

Ruby, Python, Node.js, or another application runtime may fetch thousands of rows only to perform an aggregation that the database could execute near the data.

**Primary evidence**

- rows transferred;
- SQL payload size;
- application CPU;
- allocations;
- memory;
- wall time;
- database CPU where available.

**RunDiff mapping**

Possible Findings:

~~~text
resource.cpu.time.regression
performance.wall_time.regression
database.read.volume.regression
~~~

**Remediation themes**

- SQL aggregation;
- grouped queries;
- pushing filters closer to storage;
- accepting application-side computation when business logic or portability justifies it.

**Important framing**

Do not teach "SQL is always faster." Teach execution placement and tradeoffs.

---

### 03. The Hidden Cost of One More API Call

**Family:** Network and API  
**Category:** Request amplification  
**Pattern:** Extra synchronous dependency call

**Premise**

A visually small code diff can add a network hop to every request.

**Primary evidence**

- outbound request count;
- dependency identity;
- dependency latency;
- bytes sent/received;
- request wall time.

**RunDiff mapping**

Possible Finding:

~~~text
network.request.count.changed
~~~

Possible Diagnosis:

~~~text
request_amplification
~~~

**Remediation themes**

- batch calls;
- cache;
- change data ownership;
- prefetch;
- move non-critical work off the critical path.

---

### 04. Sequential vs Parallel I/O: Why Three Fast Calls Can Still Be Slow

**Family:** Network and API  
**Category:** Execution strategy  
**Pattern:** Sequential independent I/O

**Premise**

Three individually acceptable dependency calls can create poor end-to-end latency when executed serially.

**Primary evidence**

- child dependency spans;
- dependency latency;
- wall time;
- overlap/concurrency;
- CPU versus wait time.

**RunDiff mapping**

Possible Findings:

~~~text
performance.wall_time.regression
network.request.count.changed
~~~

Potential Diagnosis:

~~~text
sequential_independent_io
~~~

**Remediation themes**

- safe concurrency;
- batching;
- timeout budgets;
- bounded fan-out;
- preserving ordering where actually required.

---

### 05. This Should Have Been a Background Job

**Family:** Async and Queues  
**Category:** Critical-path design  
**Pattern:** Non-critical synchronous work

**Premise**

Email delivery, thumbnails, webhooks, reports, and other side effects often migrate accidentally onto the user-facing request path.

**Primary evidence**

- request wall time;
- side-effect count;
- external calls;
- job count;
- queue behavior;
- dependency time.

**RunDiff mapping**

Possible Findings:

~~~text
performance.wall_time.regression
side_effect.background_job.count.changed
network.request.count.changed
~~~

**Remediation themes**

- background jobs;
- transactional outbox;
- idempotency;
- user-visible consistency expectations;
- deciding what really must complete before the response.

---

### 06. Retry Storms: When Reliability Code Causes an Outage

**Family:** Reliability  
**Category:** Retry behavior  
**Pattern:** Unbounded or synchronized retries

**Premise**

Retries can transform a partial dependency failure into an amplification loop.

**Primary evidence**

- request count;
- retry count;
- dependency errors;
- latency;
- queue growth;
- concurrency;
- CPU/network load.

**RunDiff mapping**

Potential Findings and Diagnoses:

~~~text
network.request.count.changed
retry_amplification
retry_storm_risk
~~~

**Remediation themes**

- exponential backoff;
- jitter;
- retry budgets;
- idempotency;
- circuit breakers;
- bounded attempts.

---

### 07. The Missing Index That Passed Every Test

**Family:** Database  
**Category:** Access path  
**Pattern:** Query plan regression / missing index

**Premise**

Correctness tests can remain green while data access cost changes dramatically.

**Primary evidence**

- query wall time;
- query plan where available;
- rows scanned;
- database CPU;
- I/O;
- end-to-end request latency.

**RunDiff mapping**

Possible Findings:

~~~text
performance.wall_time.regression
database.query.latency.regression
database.rows_scanned.regression
~~~

**Remediation themes**

- indexing;
- query shape;
- selectivity;
- schema design;
- representative data in test scenarios.

---

### 08. When O(n) Quietly Becomes O(n^2)

**Family:** CPU and Algorithms  
**Category:** Algorithmic complexity  
**Pattern:** Nested lookup / accidental quadratic work

**Premise**

A small implementation change can turn acceptable behavior on tiny fixtures into severe CPU growth on realistic workloads.

**Primary evidence**

- CPU time;
- wall time;
- iteration count where instrumented;
- allocations;
- input size.

**RunDiff mapping**

Likely Findings:

~~~text
resource.cpu.time.regression
performance.wall_time.regression
~~~

Potential Diagnosis:

~~~text
algorithmic_complexity_regression
~~~

**Remediation themes**

- hash/index lookups;
- precomputation;
- sorting once;
- algorithm choice;
- measuring across realistic input sizes.

---

### 09. Why Timeouts Are Part of Your Architecture

**Family:** Reliability  
**Category:** Failure boundaries  
**Pattern:** Missing or incompatible timeout budget

**Premise**

Timeouts are not a client-library detail. They define how latency and failure propagate through a dependency chain.

**Primary evidence**

- dependency latency;
- timeout events;
- request duration;
- retry count;
- cancellation propagation.

**RunDiff mapping**

Possible Findings:

~~~text
performance.wall_time.regression
runtime.error.new
~~~

Potential Diagnosis:

~~~text
timeout_budget_mismatch
~~~

**Remediation themes**

- connect/read/write/overall timeouts;
- propagation;
- deadline budgets;
- cancellation;
- retries within a total budget.

---

### 10. The Code Diff Was Small. The Behavioral Diff Wasn't.

**Family:** Architecture and Execution Placement  
**Category:** Behavioral review  
**Pattern:** Cross-signal runtime regression

**Premise**

This is the manifesto article for RunDiff.

A code diff is a textual description of implementation change. It does not describe the full runtime consequence.

**Evidence example**

~~~text
                Baseline    Candidate   Change
SQL queries          17           31     +82%
HTTP calls            4            7     +75%
p95 latency         181ms        294ms    +62%
memory               42MB         44MB     +5%
~~~

**RunDiff thesis**

~~~text
Git tells you what code changed.
RunDiff tells you what behavior changed.
~~~

This article should connect the previous nine patterns into the broader category of pre-merge behavioral validation.

## Next 20 articles

The next set expands coverage without turning the library into random performance tips.

| # | Working title | Family | Category | Primary behavioral signal |
| --- | --- | --- | --- | --- |
| 11 | SELECT * Is Not Free | Database | Read amplification | rows/bytes returned, allocations |
| 12 | The Transaction That Stayed Open Too Long | Database | Transaction scope | transaction duration, lock wait |
| 13 | Connection Pool Exhaustion Is Usually a Queueing Problem | Database | Resource contention | pool wait, queue time |
| 14 | The Join Explosion: When One Query Returns Far Too Much | Database | Cardinality amplification | rows returned, bytes, memory |
| 15 | Read Amplification: Fetching 100x More Data Than You Use | Database | Data access | rows/bytes read |
| 16 | Chatty APIs: 20 Tiny Requests vs One Useful Request | Network and API | Request amplification | request count, network time |
| 17 | Payload Creep: How a Harmless Field Turns Into Megabytes | Network and API | Payload growth | bytes transferred, serialization CPU |
| 18 | Connection Churn: Paying for DNS, TCP, and TLS Again and Again | Network and API | Connection reuse | connections, handshake time |
| 19 | Fan-Out: When One Request Becomes Fifty | Network and API | Dependency fan-out | child requests, latency distribution |
| 20 | The Slow Dependency You Accidentally Put on the Critical Path | Architecture and Execution Placement | Critical path | dependency latency, wall time |
| 21 | Allocation Explosion: Fast Code That Creates Too Much Garbage | Memory | Allocation behavior | allocations, GC time, memory |
| 22 | Buffering Everything: The Hidden Cost of Not Streaming | Memory | Buffering | peak memory, bytes buffered |
| 23 | Cache Stampede: When a Popular Key Expires | Caching | Concurrency amplification | dependency calls, lock wait, request burst |
| 24 | Cache Hit Rate Regressions After an Innocent Key Change | Caching | Cache identity | hit/miss ratio, downstream calls |
| 25 | Duplicate Jobs: At-Least-Once Delivery Meets Non-Idempotent Code | Async and Queues | Duplicate execution | job count, duplicated side effects |
| 26 | Queue Wait vs Worker Time: Find Where Async Latency Actually Lives | Async and Queues | Latency decomposition | queue wait, dispatch wait, worker wall time |
| 27 | Thundering Herd: When Everyone Wakes Up at Once | Concurrency | Coordinated contention | concurrency, dependency load, lock wait |
| 28 | Lock Contention: Correct Code That Stops Scaling | Concurrency | Serialization | lock wait, CPU, wall time |
| 29 | Compression Can Save Network and Burn CPU | CPU and Algorithms | Resource tradeoff | CPU time, bytes transferred |
| 30 | The File I/O Regression Nobody Saw in Code Review | Filesystem and I/O | I/O amplification | read/write ops, bytes, wall time |

## Article metadata

Each published article should carry structured metadata that can later be reused by product documentation and machine-readable catalogs.

Example:

~~~yaml
id: n-plus-one-query
title: "The N+1 Query: When One Line Creates 1,000 Queries"
family: database
category: query_amplification
pattern: n_plus_one

product_mapping:
  domains:
    - database
  quality_dimensions:
    - performance_efficiency
  resources:
    - database
    - io
  likely_rule_ids:
    - database.query.count.regression
  likely_diagnoses:
    - probable_n_plus_one

signals:
  - db.query.count
  - db.query.fingerprint
  - performance.wall_time

audience:
  - backend_engineer
  - senior_engineer
  - staff_engineer

content_type:
  - engineering_education
  - runtime_regression
~~~

Names in `likely_rule_ids` must only be treated as stable contracts if they exist in the RunDiff Rule Registry. Proposed future names must be marked as proposed until accepted.

## Content quality rules

1. Teach the engineering problem first.
2. Do not manufacture a RunDiff angle where the evidence does not support one.
3. Distinguish measured behavior from inferred diagnosis.
4. Avoid absolute rules such as "always use SQL" or "always make it async."
5. Show tradeoffs and counterexamples.
6. Prefer baseline/candidate examples over generic benchmark claims.
7. Use realistic code in more than one ecosystem over time. Ruby/Rails may appear frequently at first, but the library should progressively cover Python, Node.js, Go, Java, Rust, and generic containerized workloads.
8. Keep the central abstraction language-neutral: runnable workload plus evidence, not framework-specific magic.
9. Link articles to stable RunDiff rule IDs when those rules exist.
10. Make each article useful even to a reader who never installs RunDiff.

## Publication sequence

### Wave 1 - establish the thesis

Publish 01-10.

The first wave should prove that behavioral regressions cut across database, network, CPU, async, reliability, and architecture.

### Wave 2 - deepen common backend behavior

Publish 11-20.

This wave expands database and network topics and builds search coverage around concrete runtime problems.

### Wave 3 - distributed and resource behavior

Publish 21-30.

This wave introduces memory, caching, queues, contention, and I/O and prepares the library for deeper evidence sources.

## Product integration direction

The long-term product should be able to link a Finding or Diagnosis to a human explanation.

Example:

~~~text
Possible N+1 query pattern

SQL query count
17 -> 31
+82.4%

Detection confidence
high - deterministic measurement

Diagnosis confidence
medium - inferred pattern

Learn why this happens
rundiff.com/library/n-plus-one-query
~~~

The article is not the detector.

The detector is not the diagnosis.

The diagnosis is not the policy decision.

The content layer explains all of them to a human.

## Related documents

- RFC 0010: Behavioral analysis model, finding taxonomy, and investigation semantics
- docs/rules/README.md
- docs/product-vision.md
- docs/product.md
- docs/architecture.md
