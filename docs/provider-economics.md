# Provider Economics v1

Checked against public rate cards on **2026-09-30**.

This is a planning model, not an invoice forecast. It deliberately keeps EUR
and USD separate and does not select a provider by inventing an exchange rate.

## Current public inputs

### Boxd cloud

- €0.049 / vCPU-hour while running;
- €0.015 / GiB-hour of actual resident RAM while running or suspended;
- €0.0001 / GiB-hour of actual written disk;
- default machine: 2 vCPU / 8 GiB / 100 GiB provisioned;
- default organization quota: 50 machines;
- hibernated machines pay disk only;
- self-host/BYOC exists under custom commercial terms.

Sources are pinned in `config/provider-economics.v1.json`.

### GitHub Actions

- standard Linux 2-core: $0.006 / minute beyond included allowance;
- each job's minutes and partial minutes are rounded up to the next whole minute;
- included minutes depend on plan;
- standard runners for public repositories can have zero direct minute charge;
- GitHub's Actions additional terms explicitly make commercial service use a
  contractual constraint.

The RunDiff managed-dispatch evidence currently measures ten successful execute
jobs:

~~~text
median job time  54.7 s
min              49.5 s
max              58.1 s
billable minute   1 per observed job
~~~

At the public private-repository Linux rate, that is a nominal marginal
`$0.006 / dispatch` before included allowances.

## Execution evidence

BOXD6 canonical execution:

~~~text
hosted managed Go median   2,252 ms
collapsed Boxd median      3,105 ms
latency premium              853 ms
Boxd / hosted              1.379x
~~~

BOXD6 Boxd cold lifecycle:

~~~text
create golden       2,119 ms
prepare golden     15,830 ms
final cleanup         108 ms
~~~

The economics model also uses a **2,278 ms estimated child-active window**
(role-critical median + pair cleanup median). This is explicitly an estimate
until Boxd billing-start semantics during fork are measured.

## Cost method

For Boxd cloud, the model separates:

1. active CPU + actual resident RAM for the reusable golden;
2. active CPU + RAM for two temporary children;
3. temporary child disk while they exist;
4. retained golden actual-written disk for all 720 hours of a 30-day month;
5. cold golden build churn.

For GitHub Actions, the model uses the observed execute-job duration and
per-job minute rounding.

The model does **not** convert EUR into USD.

## Scenario assumptions

Until RunDiff-specific RAM/disk telemetry exists, the scenarios use visible
assumptions. They are inputs, not measured facts.

| Scenario | Repos | Runs/repo/day | Retained goldens | Peak comparisons | RAM/machine | Golden disk |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Low-volume SaaS | 10 | 5 | 10 | 2 | 2 GiB | 20 GiB |
| Medium SaaS + TTL/LRU | 100 | 10 | 25 | 8 | 2 GiB | 20 GiB |
| High-concurrency SaaS | 1,000 | 20 | 200 | 50 | 3 GiB | 25 GiB |
| Customer BYOC | 100 | 10 | 50 | 20 | assumption only | assumption only |
| Customer-owned GitHub minutes | 100 | 10 | 25 | 8 | 2 GiB | 20 GiB |

## Scenario output

| Scenario | Runs / 30d | Boxd cloud estimate | GitHub nominal | GitHub assumed paid | Default Boxd quota |
| --- | ---: | ---: | ---: | ---: | --- |
| Low-volume SaaS | 1,500 | ~€14.82 | $9.00 | $9.00 | fits |
| Medium SaaS + TTL/LRU | 30,000 | ~€44.24 | $180.00 | $180.00 | fits |
| High-concurrency SaaS | 600,000 | ~€543.89 | $3,600.00 | $3,600.00 | **does not fit** |
| Customer BYOC | 30,000 | unpriced | $180.00 | $180.00 | custom |
| Customer-owned GitHub minutes | 30,000 | ~€44.24 | $180.00 | $36.00* | fits |

`*` The final scenario assumes 80% of GitHub billable minutes are absorbed by
the customer's included allowance. That is a scenario assumption, not a GitHub
plan guarantee.

These native-currency numbers must not be read as a direct Boxd-vs-GitHub
winner.

## What dominates Boxd cost

Under the low-volume 20 GiB retained-golden assumption:

~~~text
10 hibernated goldens × 20 GiB × €0.0001/GiB-hour × 720 hours
= €14.40/month
~~~

The complete low-volume Boxd scenario estimate is only about €14.82/month.

That means retained golden **disk cardinality** can dominate execution compute
for low-volume repositories. A naive "one permanent golden per fingerprint"
policy is therefore not free even though hibernation removes CPU/RAM billing.

This strengthens the need for TTL/LRU and measured actual-written disk.

## Capacity

With the default quota of 50 machines, the simple planning bound is:

~~~text
required machines =
  retained goldens
  + 2 × peak concurrent comparisons
~~~

Examples:

~~~text
low-volume:   10 + 2×2  = 14   fits
medium:       25 + 2×8  = 41   fits
high-scale:  200 + 2×50 = 300  requires raised quota / different cache / BYOC
~~~

A shared golden can serve multiple forks, so the model does not allocate one
new golden per concurrent comparison.

## Placement dimensions that are not price

A future Placement Engine must keep these as separate dimensions:

- steady-state execution latency;
- queue/start latency;
- cold-start probability;
- cache/golden hit probability;
- compute cost;
- golden idle storage cost;
- quota/concurrency pressure;
- fork-native persistent state;
- VM isolation;
- private-network/BYOC support;
- data residency;
- customer-paid or included CI capacity;
- operational complexity;
- contractual eligibility.

Do not collapse these into one opaque score yet.

## GitHub Actions constraint

The nominal GitHub cost is useful as a customer-CI comparator, but GitHub's
Actions additional terms state that Actions should not be used to provide a
stand-alone or integrated commercial application/service offering the Actions
product/service or its elements.

That means a RunDiff SaaS placement policy must not silently treat public or
paid GitHub-hosted Actions as generic resale compute. Contractual/legal review
is a separate eligibility gate.

This document is a product/engineering constraint record, not legal advice.

## BYOC

Boxd publicly advertises self-host/BYOC, but the commercial license and customer
hardware costs are custom. The v1 model therefore returns **unpriced** for BYOC
rather than substituting the Boxd cloud rate card.

The BYOC value proposition remains structurally different:

- customer-owned compute;
- private networking;
- data residency;
- fork-native prepared environments;
- potentially different capacity economics.

## Required next measurements

The current model is intentionally parameterized around the following missing
RunDiff data:

1. actual resident RAM for a prepared Node/PostgreSQL golden;
2. actual written disk for that golden including hibernation state;
3. actual resident RAM for each forked child;
4. child written-disk delta per execution;
5. billing start/end semantics during fork and cleanup;
6. queue/start latency for Boxd;
7. representative Rails/PostgreSQL golden disk/RAM;
8. cache fingerprint cardinality and hit-rate under TTL/LRU.

Those measurements should replace scenario assumptions without changing the
calculator schema.

## Reproduce

~~~bash
python3 script/provider_economics.py \
  --config config/provider-economics.v1.json \
  --output tmp/provider-economics.json \
  --markdown tmp/provider-economics.md

python3 script/provider_economics_test.py
~~~

The JSON output is the machine-readable scenario result; the Markdown output is
a generated summary.
