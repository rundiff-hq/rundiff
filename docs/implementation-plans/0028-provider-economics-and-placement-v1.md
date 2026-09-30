# Implementation Plan 0028: Provider Economics and Placement Model v1

Status: in progress

Tracking issue: #239

## Goal

Turn the BOXD6 latency evidence into a provider economics model without
prematurely choosing a global default provider.

The model must keep latency, money, capacity, contractual eligibility and
provider capabilities as separate dimensions.

## Canonical execution evidence

~~~text
BOXD6 run 36646891578

hosted managed Go median   2,252 ms
collapsed Boxd median      3,105 ms
Boxd / hosted              1.379x
median latency premium       853 ms
~~~

Boxd lifecycle:

~~~text
create golden       2,119 ms
prepare golden     15,830 ms
final cleanup         108 ms
~~~

GitHub managed-dispatch job evidence:

~~~text
n                  10
median job time    54.7 s
min                49.5 s
max                58.1 s
billable minute     1 per observed job
~~~

## Public rate cards

Checked on 2026-09-30.

### Boxd

~~~text
vCPU    €0.049 / vCPU-hour while running
RAM     €0.015 / GiB-hour actual resident
disk    €0.0001 / GiB-hour actual written
quota   50 machines by default
~~~

Hibernated machines pay disk only. Self-host/BYOC exists under custom
commercial terms.

### GitHub Actions

~~~text
Linux 2-core   $0.006 / minute
billing        each job rounds up to the next whole minute
~~~

Included allowances depend on plan.

GitHub Actions commercial-service terms are an explicit placement eligibility
constraint. The economics model records this rather than assuming GitHub-hosted
runners are generic resale compute.

## Artifacts

### Machine-readable input model

~~~text
config/provider-economics.v1.json
~~~

Contains:

- rate cards and source URLs;
- checked-at date;
- canonical execution evidence;
- measurement gaps;
- scenario assumptions.

### Calculator

~~~text
script/provider_economics.py
~~~

Produces machine-readable JSON and generated Markdown.

It uses only the Python standard library and requires no provider credentials.

### Tests

~~~text
script/provider_economics_test.py
~~~

Tests:

- GitHub job-minute rounding;
- golden disk billing;
- RAM-sensitive Boxd execution estimate;
- machine quota pressure;
- BYOC remaining unpriced;
- no implicit EUR/USD winner;
- GitHub terms constraint propagation;
- cold-cost amortization behavior.

### Human-readable report

~~~text
docs/provider-economics.md
~~~

## Cost boundaries

### Boxd steady-state estimate

The v1 execution estimate includes:

- golden CPU/RAM for the measured 3.105-second steady-state window;
- two child CPU/RAM windows using the measured-phase child-active estimate;
- child actual-written disk while children exist.

Retained golden disk is modeled separately for the full 720-hour month.

### Boxd cold cost

Golden create + prepare + final cleanup are modeled per golden build and then
amortized.

### GitHub

GitHub cost uses the observed execute-job duration, not the 2.252-second inner
executor runtime, because GitHub bills the job.

The current median 54.7-second job rounds to one billable minute.

## Uncertainty discipline

RunDiff-specific Boxd RAM and disk have not yet been measured.

Therefore the v1 scenarios contain explicit assumptions such as:

~~~text
actual RAM per running machine
actual written golden disk
child written-disk delta
golden rebuild churn
retained golden count
peak concurrent comparisons
GitHub paid-minute fraction
~~~

These fields are inputs. They are not presented as observations.

The calculator deliberately performs no EUR/USD conversion and therefore emits
no cross-currency provider ranking.

## Scenario set

The first model covers:

- low-volume SaaS;
- medium SaaS with TTL/LRU;
- high-concurrency SaaS;
- customer BYOC;
- customer-owned GitHub minutes with partial included allowance.

## Capacity model

Default Boxd quota pressure is modeled as:

~~~text
retained goldens + 2 * peak concurrent comparisons
~~~

This is a planning bound, not a scheduler implementation.

## Placement model direction

Do not introduce one weighted provider score yet.

A future Placement Engine should preserve independent facts/constraints:

~~~text
eligibility
latency
queue/start latency
cold-start probability
golden hit probability
cost
quota pressure
isolation requirement
private networking
data residency
BYOC
operational complexity
~~~

Hard constraints should filter providers before any optimization preference is
applied.

## Acceptance

- public rate cards verified against official sources;
- checked-at date and provenance stored;
- deterministic JSON input model;
- deterministic standard-library calculator;
- unit tests require no network/provider credentials;
- five required planning scenarios;
- no implicit FX conversion;
- no default provider decision;
- GitHub commercial-service terms represented as eligibility constraint;
- Boxd BYOC stays unpriced until custom costs are known;
- normal CI runs model tests;
- Markdown report records assumptions and measurement gaps.

## Next measurement slice

Replace the largest Boxd scenario assumptions with real telemetry:

1. prepared golden actual resident RAM;
2. golden actual written disk including hibernation;
3. child actual resident RAM;
4. child written-disk delta;
5. provider billing boundary during fork/cleanup.

Then rerun the same model without changing its schema.
