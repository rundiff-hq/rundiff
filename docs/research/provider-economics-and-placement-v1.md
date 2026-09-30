# Provider Economics and Placement v1

Status: research baseline

Tracking issue: #239

As of: 2026-09-30

## Question

After BOXD6, execution latency is close enough that provider selection should no
longer be reduced to a single speed comparison.

Canonical BOXD6 evidence:

~~~text
Hosted managed Go median   2,252 ms
Collapsed Boxd median      3,105 ms
Boxd / hosted              1.379x
median latency premium       853 ms
~~~

The provider decision now depends on:

- execution cost;
- reusable-golden storage cost;
- queue/startup behavior;
- concurrency/quota;
- isolation;
- persistent state;
- data residency/BYOC;
- commercial/contractual eligibility.

## Sources and rate cards

Rates are intentionally timestamped. Re-check before any product pricing or
placement policy change.

### Boxd

Source: https://boxd.sh/pricing

Published rate card:

~~~text
vCPU                 €0.049 / vCPU-hour while running
resident RAM         €0.015 / GiB-hour
written disk         €0.0001 / GiB-hour
default machine      2 vCPU / 8 GiB / 100 GiB provisioned
approx running rate  €0.22 / hour
default quota        50 machines
~~~

RAM is billed on actual resident memory rather than provisioned RAM. Disk is
billed on actual written disk rather than provisioned disk. Hibernated machines
pay disk only.

The public pricing page also advertises custom/self-host/BYOC arrangements.

### GitHub Actions

Sources:

- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://docs.github.com/en/actions/how-tos/monitor-workflows/view-job-execution-time
- https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features

Current private standard Linux runner:

~~~text
2 vCPU / 8 GiB
$0.006 / minute beyond included quota
billable job time rounds up to the next minute
~~~

Current included standard-runner minutes per month include:

~~~text
Free                    2,000
Pro                     3,000
Free organization       2,000
Team                    3,000
Enterprise Cloud       50,000
~~~

These allowances are shared account entitlements, not dedicated RunDiff
capacity.

Standard GitHub-hosted runners are free in public repositories. That is not a
valid reason to model the current public RunDiff proof repository as free
commercial compute. GitHub's Actions additional terms explicitly constrain
commercial services that offer Actions or elements of Actions. Whether a
specific RunDiff managed architecture falls within that language requires
terms/legal review before production use.

## Observed GitHub managed-dispatch job time

The current `RunDiff Executor Dispatch` workflow uses
`runs-on: ubuntu-24.04` in the public `rundiff-hq/rundiff` repository.

GitHub currently assigns different standard-runner hardware by repository
visibility:

~~~text
public ubuntu-24.04   4 vCPU / 16 GiB
private ubuntu-24.04  2 vCPU / 8 GiB
~~~

The 10 sampled recent successful public-repository `execute` jobs had log
durations:

~~~text
57.3  49.5  57.6  55.2  57.1
51.2  58.1  52.6  54.2  53.6 seconds
~~~

Summary:

~~~text
median  54.7 s
mean    54.64 s
min     49.5 s
max     58.1 s
~~~

All ten observed public-runner jobs fit inside one minute. That observation is
useful for workflow overhead, but it is **not** a measured private-runner paid
cost because the private standard runner has half the CPU and RAM.

Therefore v1 models private GitHub cost as sensitivity rather than a point
estimate:

~~~text
1 billable minute / execution  -> $0.006
2 billable minutes / execution -> $0.012
~~~

A private 2-vCPU / 8-GiB measurement is required before choosing one of those
as the expected paid cost.

This is more methodologically correct than multiplying the 2.252-second inner
executor benchmark by the GitHub minute rate. GitHub bills the whole job and
rounds billable job time up to the next minute.

## Boxd active execution envelope

BOXD6 canonical steady-state median:

~~~text
3.105 s
~~~

We do not yet have provider billing telemetry for exact resident RAM per
machine, so v1 deliberately uses the published approximate default-machine
rate of €0.22/hour as a conservative rate basis.

Two execution envelopes are modeled.

### Lower envelope

Count:

- parent golden for the full 3.105 s sample;
- baseline and candidate after pair-ready through role critical path + cleanup.

~~~text
parent               3.105 machine-seconds
baseline child       2.278 machine-seconds
candidate child      2.278 machine-seconds
total                7.661 machine-seconds

estimated active compute
≈ €0.00046817 / execution
~~~

This excludes unknown child billing during the fork itself and is not a strict
lower bound on provider invoices.

### Conservative envelope

Charge parent + baseline + candidate for the full 3.105-second sample:

~~~text
3 × 3.105 = 9.315 machine-seconds

estimated active compute
≈ €0.00056925 / execution
~~~

Because Boxd bills actual resident RAM, actual compute can differ from this
default-machine-rate approximation.

## Cold golden construction

Canonical BOXD6 lifecycle:

~~~text
create golden       2.119 s
prepare golden     15.830 s
cold setup total   17.949 s
final cleanup       0.108 s
~~~

At the same approximate €0.22/hour running rate:

~~~text
cold setup compute  ≈ €0.00109688 / golden
final cleanup       ≈ €0.00000660 / golden
~~~

Cold compute itself is tiny. Golden retention is potentially much more
important.

## Hibernated golden storage

Boxd bills hibernated machines for written disk.

Illustrative 30-day month:

| Written disk per golden | Monthly cost per golden |
| ---: | ---: |
| 5 GiB | €0.36 |
| 10 GiB | €0.72 |
| 20 GiB | €1.44 |

This is why the number of retained fingerprints matters.

A cache key includes at least:

~~~text
repo
runtime/toolchain
lockfile
service topology
RunDiff tool revision
base image
~~~

RunDiff should not retain every historical fingerprint indefinitely.

The production design needs:

- hot-golden TTL;
- LRU/usage policy;
- maximum goldens per customer/repository;
- explicit refresh/eviction;
- measurement of actual written disk;
- later evaluation of snapshots/checkpoints as a colder catalog tier.

## Illustrative fleet scenarios

These are sensitivity examples, not forecasts. They assume 10 GiB written disk
per hot golden and the BOXD6 active-compute envelopes.

### Low volume

~~~text
monthly executions  1,000
hot goldens          5
default-quota pair concurrency 22

Boxd:
  golden storage             €3.60
  active compute             €0.47 - €0.57
  total                      €4.07 - €4.17

GitHub private sensitivity:
  1 min/execution, no allowance   $6.00
  2 min/execution, no allowance  $12.00
  Team allowance fully free:
    1 min/execution                $0.00
    2 min/execution                $0.00
~~~

At low volume, golden retention dominates Boxd compute.

### Medium volume

~~~text
monthly executions  10,000
hot goldens          20
default-quota pair concurrency 15

Boxd:
  golden storage             €14.40
  active compute             €4.68 - €5.69
  total                      €19.08 - €20.09

GitHub private sensitivity:
  1 min/execution, no allowance   $60.00
  2 min/execution, no allowance  $120.00
  Team allowance fully free:
    1 min/execution                $42.00
    2 min/execution               $102.00
  Enterprise allowance fully free:
    1 min/execution                 $0.00
    2 min/execution                 $0.00
~~~

### High volume

~~~text
monthly executions  100,000
hot goldens          40
default-quota pair concurrency 5

Boxd:
  golden storage             €28.80
  active compute             €46.82 - €56.93
  total                      €75.62 - €85.73

GitHub private sensitivity:
  1 min/execution, no allowance    $600.00
  2 min/execution, no allowance  $1,200.00
  Team allowance fully free:
    1 min/execution                 $582.00
    2 min/execution               $1,182.00
  Enterprise allowance fully free:
    1 min/execution                 $300.00
    2 min/execution                 $900.00
~~~

At this point Boxd's default 50-machine quota becomes a stronger constraint
than raw compute cost. Custom quota or BYOC would be required for meaningful
parallelism if 40 persistent goldens really existed at once.

EUR and USD are intentionally not converted. Product pricing must not embed a
stale FX rate.

## Placement should be constrained, not globally ranked

### GitHub public RunDiff-managed runner

Current status:

~~~text
proof / research only
~~~

Do not make this the commercial managed-compute strategy based on the public
repository's zero runner bill. Terms eligibility must be resolved first.

### Customer-owned private GitHub Actions

Potential fit:

- low-volume repositories;
- customer is comfortable paying/using its own included Actions minutes;
- no need for fork-native persistent state;
- workload is directly related to the customer's repository;
- simple onboarding is more valuable than golden reuse.

Costs are charged to the repository owner, not RunDiff.

### Managed Boxd

Potential fit:

- active repositories with repeated comparisons;
- persistent services or expensive bootstrap;
- fork-native baseline/candidate isolation is valuable;
- RunDiff wants direct control over compute lifecycle;
- EU placement is useful;
- the hot-golden cache can be bounded.

### Boxd BYOC / self-host

Potential enterprise fit:

- customer-controlled compute;
- private networking;
- data residency;
- dedicated capacity;
- larger/custom machine shapes;
- desire to keep source/runtime evidence inside customer infrastructure.

## Placement inputs

The future Placement Engine should receive explicit facts instead of a single
provider priority list:

~~~text
terms_eligible
customer_pays_compute
requires_byoc
requires_private_network
requires_data_residency
supports_fork_native_state
golden_available
golden_hotness
estimated_bootstrap_cost
estimated_execution_cost
estimated_queue_latency
estimated_execution_latency
provider_quota_headroom
required_cpu
required_ram
required_disk
runtime
service_topology
~~~

Then policy can choose among eligible providers.

## What remains unknown

Before using the model for production pricing:

1. measure actual written disk of Node and Rails goldens;
2. obtain actual Boxd resident-memory/billing telemetry if exposed;
3. measure hibernate -> fork ready latency;
4. verify whether hibernated machines consume the 50-machine quota;
5. measure Boxd queue/control-plane latency under concurrent load;
6. measure the dispatch workflow on private-equivalent 2-vCPU / 8-GiB GitHub hardware;
7. measure GitHub runner queue time separately from execution time;
8. decide whether customer-owned GitHub Actions is a supported product mode;
9. get explicit terms/legal review before using GitHub Actions as RunDiff-managed
   commercial compute;
10. model custom Boxd/BYOC pricing when available.

## Files

Source data:

~~~text
docs/research/data/provider-economics-v1.json
~~~

Deterministic model:

~~~text
python3 script/provider_economics.py
~~~

Contract:

~~~text
python3 -m unittest script/provider_economics_test.py
~~~

The model deliberately keeps current rate-card inputs separate from formulas so
rates can be refreshed without rewriting placement logic.
