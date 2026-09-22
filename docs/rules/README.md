# RunDiff Rule Registry

This directory documents the target shape of stable behavioral analysis rules.

It documents the runtime Rule Registry introduced by PR #174.

`RunDiff::RuleRegistry` now owns the current signal comparison policy, legacy reason-code mapping, stable rule IDs, default severity, thresholds, and classification facets.

`RunDiff::BehavioralDiff` consumes the registry and remains the comparison engine.

RFC 0010 defines the longer migration toward normalized Findings, evidence references, richer confidence, exporters, and causal investigation.

## Rule versus Finding

A Rule is reusable:

~~~text
database.query.count.regression
~~~

A Finding is one concrete application of that rule:

~~~text
checkout.create-order
17 -> 31 SQL queries
+82.4%
~~~

## Stable identifier rule

Use lower-case dotted identifiers:

~~~text
<domain>.<subject>.<measurement-or-behavior>.<change>
~~~

Examples:

~~~text
performance.wall_time.regression
resource.cpu.time.regression
async.queue.wait.regression
database.query.count.regression
network.request.count.changed
runtime.error.new
~~~

Rule IDs are machine contracts.

Human titles and messages may evolve independently.

## Facets

Do not make folder nesting the ontology.

A rule can carry multiple independent facets:

- domains;
- quality dimensions;
- resources;
- default scope;
- change kind.

Example:

~~~yaml
id: database.query.count.regression

domains:
  - database

quality_dimensions:
  - performance_efficiency

resources:
  - database
  - io
~~~

## Standards mapping

- OpenTelemetry Semantic Conventions inform evidence names where appropriate.
- ISO/IEC 25010:2023 informs high-level quality dimensions where useful.
- SARIF informs rule/result/exporter design.
- IEC 62740 informs later investigation and root-cause semantics.

RunDiff owns its internal rule/finding model.

## Compatibility

Schema v1 findings expose both:

~~~yaml
reason_code: DATABASE_QUERY_REGRESSION
rule_id: database.query.count.regression
~~~

Legacy reason codes remain supported until all consumers migrate.

The registry is currently implemented in Ruby. Its file format is not a public contract; stable `rule_id` values are.

See RFC 0010.
