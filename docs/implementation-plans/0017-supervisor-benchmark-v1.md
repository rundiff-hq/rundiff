# Implementation Plan 0017: Ruby vs Go Supervisor Benchmark v1

## Goal

Measure the supervisor/runtime overhead that remains after removing customer workload and dependency-cache effects.

This benchmark exists specifically to answer a different question from VS13 and VS15:

~~~text
VS13: how much does dependency caching save?
VS15: how much wall time does that cache remove from a full managed execution?
VS16: what is the process-level Ruby-vs-Go supervisor cost itself?
~~~

## Compared entrypoints

Ruby uses the historical production executor bridge entrypoint:

~~~text
bundle exec ruby script/run_cloudflare_executor_bridge.rb
~~~

It loads the same Rails environment as the old Ruby-owned executor, reports a benchmark ready marker, then remains idle.

Go uses the production executor binary:

~~~text
rundiff-executor supervisor-benchmark-idle
~~~

It reports the same ready marker and remains idle.

No Bundler install, Git clone, DB preparation, service startup, sensor capture, or behavioral comparison occurs inside the measured interval.

## Sequential measurements

Ten paired alternating repetitions measure:

- process start -> supervisor ready wall time;
- CPU consumed by the process tree before ready;
- idle RSS;
- idle PSS;
- high-water RSS;
- thread count;
- file-descriptor count;
- process-tree size.

Alternating order reduces simple runner-warmth bias.

## Why PSS as well as RSS

RSS counts shared pages in every process and can overstate host capacity when many identical runtimes are resident.

PSS divides shared pages proportionally across processes.

For concurrency/capacity discussion, PSS is therefore more informative than summing RSS alone.

## Concurrency cohorts

The workflow holds idle supervisors resident at:

~~~text
1
5
10
~~~

concurrent processes for Ruby and Go and records aggregate RSS/PSS.

This is a supervisor-footprint test, not a customer-workload concurrency test.

## 10,000 model

The harness derives:

- aggregate startup wall time for 10,000 starts;
- aggregate startup CPU for 10,000 starts;
- a linear 10,000-idle-process PSS projection from the largest measured cohort.

The memory number must remain explicitly labeled as a projection, not a measured 10,000-concurrent proof.

## Claim discipline

This benchmark can support statements about:

- supervisor startup;
- process footprint;
- idle concurrency;
- aggregate startup overhead.

It cannot support statements about:

- Bundler/npm performance;
- database performance;
- customer application CPU;
- complete execution speedup;
- 10,000 simultaneous full customer workloads.

Those have separate evidence or remain future work.
