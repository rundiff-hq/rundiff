# RFC 0010: Behavioral analysis model, finding taxonomy, and investigation semantics

## Status

Accepted direction. Migration is incremental and must not break the current Executor Request/Result v1 contract.

## Context

RunDiff already produces useful behavioral findings, but the current implementation encodes most analysis semantics inside a flat `BehavioralDiff::SIGNALS` hash.

Current reason codes include:

~~~text
PERFORMANCE_REGRESSION
CPU_TIME_REGRESSION
QUEUE_WAIT_REGRESSION
DISPATCH_WAIT_REGRESSION
WORKER_LATENCY_REGRESSION
DATABASE_QUERY_REGRESSION
SIDE_EFFECT_CHANGED
NETWORK_BEHAVIOR_CHANGED
NEW_RUNTIME_ERROR
~~~

This has been sufficient for the first vertical slices, but it mixes several different conceptual levels:

- evidence signal;
- analysis rule;
- finding category;
- quality impact;
- resource/domain ownership;
- diagnosis;
- execution failure;
- decision.

For example, `PERFORMANCE_REGRESSION` is broad, `DATABASE_QUERY_REGRESSION` is specific, and `SIDE_EFFECT_CHANGED` describes a different semantic axis entirely.

As Standard, Performance, and Deep evidence expand into database, CPU, memory, disk I/O, network, process, container, queue, filesystem, dependency, and eBPF signals, a flat list of reason codes will not scale.

## Core decision

Keep the portable executor transport boundary:

~~~text
RunDiff::Executor::Request
        |
        v
     Executor
        |
        v
RunDiff::Executor::Result
~~~

These names remain appropriate.

Inside and after the execution boundary, model analysis explicitly:

~~~text
Execution
   |
   v
Evidence
   |
   v
Rule
   |
   v
Finding
   |
   +--> Diagnosis
   |
   +--> Relations / Causal Graph
   |
   v
Decision
~~~

Execution Failure is a separate concept and does not become a Finding merely because both are "bad".

## Canonical analysis concepts

### Evidence

A recorded observation or measurement.

Examples:

~~~text
SQL query count: 17
wall time: 182 ms
CPU time: 94 ms
outbound HTTP requests: 4
TCP retransmits: 0
new exception: ActiveRecord::RecordNotFound
~~~

Evidence answers:

> What did we actually observe?

Evidence must preserve provenance.

Potential provenance includes:

- framework-native instrumentation;
- OpenTelemetry;
- process/cgroup metrics;
- eBPF;
- network probes;
- driver artifacts;
- executor/runtime metadata.

Evidence must not contain an inferred root cause merely because an analysis engine later associates it with one.

### Rule

A stable definition of what RunDiff considers analytically meaningful.

Example:

~~~yaml
id: database.query.count.regression
title: Database query count increased
kind: regression
signal: db.query.count
default_severity: high
comparison:
  direction: increase
  threshold_percent: 25
~~~

A Rule is reusable across reviews.

A Finding is one application of a Rule to one concrete comparison.

This separation is intentionally similar to the useful Rule/Result distinction in SARIF, without making RunDiff's internal schema equal to SARIF.

### Finding

A concrete, evidence-backed behavioral change detected in one Behavioral Review.

Example:

~~~yaml
rule_id: database.query.count.regression

kind: regression

domains:
  - database

quality_dimensions:
  - performance_efficiency

resources:
  - database
  - io

scope:
  role: request

signal:
  name: db.query.count

change:
  baseline: 17
  candidate: 31
  delta: 14
  delta_percent: 82.4

severity: high

confidence:
  level: high
  basis: deterministic_measurement
~~~

A Finding answers:

> What meaningful change did RunDiff detect?

A Finding is not automatically a root cause.

### Diagnosis

An interpretation of one or more findings/evidence items.

Examples:

~~~text
CPU-bound request
queue-dominated async latency
possible N+1 query pattern
downstream dependency slowdown
memory growth concentrated in worker phase
~~~

Diagnosis answers:

> What pattern best explains the observations?

A diagnosis must carry an explicit confidence/basis and must distinguish deterministic classification from inference.

Example:

~~~yaml
classification: probable_n_plus_one
confidence:
  level: medium
  basis: inferred_pattern
~~~

### Relation

A typed edge between findings, diagnoses, dependencies, or evidence-derived entities.

Initial relation vocabulary may include:

~~~text
depends_on
contributes_to
causes
correlates_with
upstream_of
downstream_of
same_cause_as
~~~

Relations are not all causal.

A relation must declare epistemic status, for example:

~~~text
observed
inferred
hypothesis
confirmed
~~~

RunDiff must not promote `correlates_with` or `contributes_to` into `causes` without sufficient evidence.

### Decision

The policy outcome derived from findings and execution state.

Examples:

~~~text
ALLOW
REVIEW
BLOCK
INFRA_FAILURE
~~~

Decision is separate from diagnosis.

A Finding may exist without blocking.

A Diagnosis may be uncertain while a deterministic threshold Finding still justifies a policy decision.

### Execution Failure

Failure of the execution machinery or requested workload to produce the intended evidence contract.

Examples include:

~~~text
PROVIDER_INFRA_FAILURE
CAPABILITY_MISMATCH
BOOTSTRAP_FAILURE
BUILD_FAILURE
READY_TIMEOUT
EXECUTION_TIMEOUT
OOM
DISK_EXHAUSTED
CANCELLED
SUPERSEDED
SENSOR_FAILURE
CLEANUP_FAILURE
~~~

Execution Failure answers:

> Why could this execution not produce the intended result?

It is not a behavioral Finding about the candidate unless the failure itself is the subject behavior being compared.

## Findings use facets, not one taxonomy tree

Do not force every finding into one hierarchical category tree.

One finding may simultaneously be:

- database-related;
- performance-related;
- I/O-related;
- dependency-related.

Therefore RunDiff uses orthogonal facets.

### Domain

What technical/application area is involved?

Initial vocabulary may include:

~~~text
application
database
network
async
runtime
filesystem
external_dependency
process
container
host
~~~

### Quality dimension

What product-quality property is affected?

Where useful, RunDiff maps high-level quality dimensions to ISO/IEC 25010:2023 concepts rather than inventing incompatible top-level quality vocabulary.

Examples likely relevant to RunDiff include:

~~~text
functional_suitability
performance_efficiency
compatibility
reliability
security
maintainability
~~~

RunDiff does not claim ISO/IEC 25010 conformity merely because it reuses compatible terminology.

### Resource

What constrained or measured resource is involved?

Initial vocabulary:

~~~text
cpu
memory
database
disk
io
network
queue
process
thread
external_service
~~~

### Scope

Where did the observation occur?

Examples:

~~~text
scenario
request
job
worker
process
container
host
dependency
~~~

### Change kind

How did candidate behavior differ?

Examples:

~~~text
increase
decrease
appeared
disappeared
changed
reordered
duplicated
missing
~~~

### Causal role

What role does this item currently play in investigation?

Examples:

~~~text
symptom
contributing_factor
candidate_cause
confirmed_cause
context
~~~

Causal role must not be inferred solely from CODEOWNERS, source attribution, or correlation.

## Confidence is multi-dimensional

Avoid one universal confidence number when different kinds of certainty are involved.

At minimum distinguish:

### Detection confidence

How certain are we that the measured behavioral change exists?

Examples:

~~~text
deterministic_measurement
statistical_comparison
threshold_exceeded
~~~

### Attribution confidence

How certain are we about the source/component attribution?

Current vocabulary already includes useful ideas such as:

~~~text
explicit
runtime
~~~

This may later evolve into a versioned attribution model.

### Diagnosis confidence

How certain are we about the interpretation/root-cause hypothesis?

Examples:

~~~text
deterministic_classification
inferred_pattern
hypothesis
confirmed
~~~

Performance Evidence additionally carries environment/noise confidence as defined in RFC 0004.

## Standards mapping

RunDiff should reuse established semantics where they help, but should not force its domain model into one external standard.

### SARIF 2.1.0

OASIS SARIF provides useful prior art for:

- stable rule identity;
- result instances;
- severity/level;
- source locations;
- fingerprints;
- code flows;
- properties/tags.

RunDiff should adopt compatible architectural ideas:

~~~text
RunDiff Rule    ~ SARIF reportingDescriptor/rule
RunDiff Finding ~ SARIF result
~~~

But RunDiff is not primarily a static-analysis format and needs baseline/candidate deltas, execution provenance, evidence sources, performance confidence, and causal/investigation semantics.

Therefore:

> RunDiff owns its internal Finding model and may provide a SARIF exporter.

Do not make SARIF the internal storage schema.

Official reference:
https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html

### OpenTelemetry Semantic Conventions

Use OpenTelemetry Semantic Conventions preferentially for telemetry/evidence vocabulary where a suitable stable or explicitly versioned convention exists.

Examples include concepts around:

- database operations;
- HTTP;
- messaging;
- process/runtime;
- system;
- containers;
- CI/CD;
- errors.

Boundary:

~~~text
OpenTelemetry Semantic Conventions
  -> evidence vocabulary / normalization

RunDiff
  -> comparison rules / findings / diagnoses / decisions
~~~

RunDiff Evidence must not become an OpenTelemetry schema.

Semantic convention stability varies by area, so RunDiff must record the convention/schema version when normalized evidence depends on a versioned convention.

Official reference:
https://opentelemetry.io/docs/specs/semconv/

### ISO/IEC 25010:2023

ISO/IEC 25010:2023 defines a product quality model with characteristics and subcharacteristics.

RunDiff may align its high-level `quality_dimensions` vocabulary with this model where useful.

This is a classification aid, not a claim that a Behavioral Review is an ISO conformity assessment.

Official reference:
https://www.iso.org/standard/78176.html

### IEC 62740:2015

IEC 62740 describes principles and a process for Root Cause Analysis.

Useful ideas for RunDiff include:

- distinguish the focus event from its causes;
- investigate contributing/root causes explicitly;
- select an RCA technique appropriate to evidence;
- do not use RCA to assign responsibility/liability.

IEC 62740 focuses on a posteriori analysis of occurred events. RunDiff operates pre-merge, but every baseline/candidate execution is still an occurred controlled experiment that can be investigated after execution.

RunDiff may borrow investigation semantics and discipline without claiming IEC 62740 conformity.

Official reference:
https://webstore.iec.ch/en/publication/21810

## Rule identifiers

New stable rules should use lower-case dotted identifiers.

Pattern:

~~~text
<domain>.<subject>.<measurement-or-behavior>.<change>
~~~

Examples:

~~~text
performance.wall_time.regression
resource.cpu.time.regression
async.queue.wait.regression
async.dispatch.wait.regression
async.worker.wall_time.regression
database.query.count.regression
side_effect.background_job.count.changed
side_effect.email.count.changed
network.request.count.changed
runtime.error.new
~~~

Rule IDs are stable machine contracts.

Human titles/messages may evolve independently.

## Current v1 reason-code migration

Current `reason_code` values remain supported in schema v1.

Initial migration mapping:

| Current reason_code | Target rule_id |
| --- | --- |
| PERFORMANCE_REGRESSION | performance.wall_time.regression |
| CPU_TIME_REGRESSION | resource.cpu.time.regression |
| QUEUE_WAIT_REGRESSION | async.queue.wait.regression |
| DISPATCH_WAIT_REGRESSION | async.dispatch.wait.regression |
| WORKER_LATENCY_REGRESSION | async.worker.wall_time.regression |
| DATABASE_QUERY_REGRESSION | database.query.count.regression |
| NETWORK_BEHAVIOR_CHANGED | network.request.count.changed |
| NEW_RUNTIME_ERROR | runtime.error.new |

`SIDE_EFFECT_CHANGED` is intentionally not one future rule. It should split according to the actual signal, initially:

~~~text
background_jobs -> side_effect.background_job.count.changed
emails          -> side_effect.email.count.changed
~~~

During migration a Finding may expose both:

~~~yaml
reason_code: DATABASE_QUERY_REGRESSION
rule_id: database.query.count.regression
~~~

until all consumers can rely on stable rule IDs.

## Rule Registry

The current `BehavioralDiff::SIGNALS` hash is implementation policy, not the long-term ontology.

Target shape:

~~~text
docs/rules/              design/examples now

future implementation:
  rule registry
    performance.wall_time.regression
    resource.cpu.time.regression
    database.query.count.regression
    ...
~~~

The final implementation may be Ruby, YAML-backed, generated data, or another versioned representation.

Do not make file layout itself part of the public contract.

Rule Registry should own at least:

- stable rule ID;
- title/description;
- signal(s);
- kind;
- facets;
- default severity;
- comparison semantics;
- evidence requirements;
- documentation reference;
- schema/version metadata.

Policy overrides such as repository thresholds belong above the default Rule definition.

## Result naming

Keep:

~~~text
RunDiff::Executor::Request
RunDiff::Executor::Result
~~~

They describe a transport/execution envelope and are not confusing at that boundary.

However, current nested payload naming can produce the conceptual shape:

~~~text
Executor::Result
  -> result
~~~

For a future breaking schema revision, prefer a domain name such as:

~~~text
Executor::Result
  -> assessment
      -> findings
      -> diagnoses
      -> decision
~~~

Do not rename the v1 field merely for aesthetics. Schema compatibility is more important than immediate naming purity.

## Candidate future Finding shape

Illustrative only:

~~~yaml
schema_version: 2
id: finding-01
rule_id: database.query.count.regression
kind: regression

facets:
  domains:
    - database
  quality_dimensions:
    - performance_efficiency
  resources:
    - database
    - io

scope:
  role: request

signal:
  name: db.query.count

change:
  baseline: 17
  candidate: 31
  delta: 14
  delta_percent: 82.4

severity: high

confidence:
  detection:
    level: high
    basis: deterministic_measurement
  attribution:
    level: medium
    basis: runtime

source:
  path: app/controllers/users_controller.rb
  start_line: 42
  end_line: 42

evidence_refs:
  - evidence-017
  - evidence-018

causal_role: symptom
relations: []

fingerprint: database.query.count.regression:checkout.create-order
~~~

## Candidate future Diagnosis shape

Illustrative only:

~~~yaml
id: diagnosis-01
classification: probable_n_plus_one

finding_refs:
  - finding-01

confidence:
  level: medium
  basis: inferred_pattern

evidence_refs:
  - evidence-017
  - evidence-018

status: hypothesis
~~~

LLMs may explain or propose diagnoses, but deterministic evidence and explicit inference status remain authoritative.

## Causal graph

The long-term investigation layer is a graph, not a nested category tree.

Example:

~~~text
database.query.count.regression
        |
        | contributes_to [inferred]
        v
performance.wall_time.regression
        |
        | correlates_with [observed]
        v
resource.cpu.time.regression
~~~

Another example:

~~~text
network.request.latency.regression
        |
        | depends_on [observed]
        v
external dependency: payments.example.com
~~~

A causal edge must carry:

- type;
- epistemic status;
- confidence/basis;
- evidence references;
- optional source/target scope.

This prepares RunDiff for investigation without pretending correlation is causation.

## Ownership and routing interaction

RFC 0008 consumes Findings.

Ownership and routing must remain downstream:

~~~text
Evidence
 -> Finding
 -> Diagnosis / relations
 -> Decision
 -> Ownership Resolver
 -> Routing
~~~

CODEOWNERS can answer who owns a path.

It cannot change the causal role of a Finding.

## UI implications

Control Panel and GitHub presentation should group Findings by facets rather than exposing an unstructured flat list.

Potential views:

~~~text
By domain
  Database (3)
  Network  (1)

By impact
  Performance efficiency (4)
  Reliability (1)

By resource
  CPU (2)
  I/O (3)

Investigation
  Symptoms (2)
  Contributing factors (3)
  Hypotheses (1)
~~~

The default UI should still prioritize the few findings that explain the decision rather than dump the entire ontology.

## Agent contract implications

Agents should receive:

- stable rule IDs;
- raw delta/evidence references;
- source attribution;
- facets;
- confidence basis;
- relation edges;
- decision relevance;
- recommended next action.

Do not require agents to parse human prose to learn why a Behavioral Review blocked.

## Implementation sequence

### Phase 0 - documentation and compatibility

- define canonical concepts and taxonomy;
- keep Request/Result v1 unchanged;
- keep current reason codes;
- add Rule Registry design/examples.

### Phase 1 - Rule Registry behind current output

Implemented by PR #174:

- introduce `RunDiff::RuleRegistry`;
- move thresholds, severity, decision/optional semantics, legacy reason-code mapping, and facets out of `BehavioralDiff::SIGNALS`;
- emit stable `rule_id` alongside legacy `reason_code`;
- emit additive Finding facets;
- preserve current thresholds/decisions.

### Phase 2 - normalized Finding model

- add facets;
- explicit evidence references;
- split side-effect rules;
- formalize confidence dimensions;
- add stable fingerprints.

### Phase 3 - exporters and UI

- SARIF exporter where useful;
- Control Panel grouping/filtering;
- machine-readable rule documentation;
- OTel semantic-convention-aware evidence normalization.

### Phase 4 - investigation graph

- typed relations;
- diagnosis entities;
- hypothesis/confirmation lifecycle;
- explicit causal evidence;
- agent investigation workflows.

## Consequences

### Positive

- new evidence sources do not create an uncontrolled flat reason-code list;
- UI can group findings by domain, resource, quality impact, or causal role;
- agents receive stable machine semantics;
- SARIF export remains possible;
- OTel vocabulary can be reused without making OTel the RunDiff model;
- performance and Deep evidence fit the same analysis architecture;
- causal investigation can evolve without rewriting basic findings.

### Costs

- taxonomy governance becomes a real responsibility;
- rule IDs become durable contracts;
- external standard mappings require version awareness;
- diagnosis/causal confidence is more complex than one severity value;
- v1/v2 migration must preserve existing consumers.

## Non-goals

This RFC does not:

- claim RunDiff conforms to SARIF, ISO/IEC 25010, or IEC 62740;
- require implementing a full ontology engine now;
- require an LLM for diagnosis;
- make every correlation causal;
- replace OpenTelemetry Semantic Conventions;
- rename Executor::Request or Executor::Result;
- break schema v1;
- define every future rule in advance.

## Related work

- ADR 0004: OpenTelemetry and W3C context
- ADR 0005: Separate human and agent contracts
- ADR 0012: Ownership-aware routing is separate from causality
- RFC 0001: Agent-readable result contract
- RFC 0004: Execution planning, compute, placement, and evidence strategy
- RFC 0006: Portable execution and multi-source evidence
- RFC 0008: Ownership-aware finding routing
- RFC 0009: Managed Go Executor host runtime
- docs/definitions.md
