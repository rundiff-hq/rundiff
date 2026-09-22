# Implementation Plan 0016: Whole-Execution Cache Benchmark v1

## Goal

Measure the practical wall-clock effect of Dependency Cache v1 across the complete managed Go executor path.

VS13 proved the isolated dependency-bootstrap effect:

~~~text
cold dependency bootstrap median  34.450 s
warm dependency bootstrap median   0.348 s
~~~

VS15 answers the next question:

~~~text
How many seconds does a warm dependency cache remove from one complete managed executor execution?
~~~

## Scope

The benchmark executes the same core used by the production Go agent:

~~~text
Prepare
  -> Clone
  -> Auto Bootstrap
  -> Auto Subject Prepare
  -> Services / Ready
  -> runtime sensor capture
  -> Go comparison
  -> Collect
  -> Stop
  -> Teardown
~~~

It deliberately excludes:

~~~text
GitHub provider queue time
control-plane dispatch latency
claim / heartbeat network latency
GitHub Check publication latency
~~~

Those are orchestration/provider costs rather than executor execution cost and should be measured separately by the external acceptance fixture.

## Local managed command

VS15 adds:

~~~bash
rundiff-executor run-local   --request request.json   --result result.json   --journal journal.jsonl   --metrics metrics.jsonl   --cwd .
~~~

This invokes the same managed engine construction as the production agent without requiring a live control plane.

## Cold / warm method

Each benchmark pair gets a fresh RunDiff dependency-cache root:

~~~text
pair N
  fresh cache root
    -> complete managed execution = cold
    -> complete managed execution = warm
~~~

The baseline SHA, candidate SHA, scenario, repository namespace, runtime, package-manager versions, and runner remain the same inside a pair.

The warm execution reuses only the executor dependency-cache root intentionally. Worktrees, subject databases, services, capture outputs, journals, and execution IDs are recreated.

## Evidence

For every execution the harness keeps:

- Request v1;
- Result v1;
- Resource Journal;
- phase metrics;
- wall-clock duration.

The summary reports cold/warm count, median, p95, min, max, median seconds saved, median speedup, and median percentage reduction.

## Interpretation

This benchmark measures the practical same-runner wall-clock effect of a warm RunDiff cache.

A warm run may also benefit from normal operating-system page cache and process-level runner warmth. Therefore the result is the observed practical end-to-end executor improvement, not a claim that every saved millisecond comes exclusively from dependency artifacts.

VS13 remains the isolated proof that the dependency bootstrap itself changes from miss to hit with a stable cache identity.

## Acceptance

- local command uses the same managed engine path as the production Go agent;
- three independent cold -> warm pairs on GitHub Actions;
- fresh RunDiff cache root per pair;
- successful Result v1 required for every sample;
- raw per-run metrics/journal/result retained;
- median and p95 whole-execution wall-clock evidence;
- benchmark artifact retained for 14 days;
- normal CI and isolated Compose proof remain green.
