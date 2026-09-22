# Implementation Plan 0011: Go Executor Vertical Slice 9

## Goal

Move execution reduction, behavioral comparison, and trusted-source attribution into Go.

VS8 made Go the owner of baseline/candidate capture orchestration, but the managed path still spawned `script/rundiff_compare_captures.rb` after both Rails sensors finished. VS9 removes that compatibility subprocess.

## Target boundary

~~~text
Go
  Prepare -> Clone -> Bootstrap -> SubjectPrepare
  -> Start -> Ready
  -> Scenario orchestration
       -> Ruby Rails sensor (base)
       -> Ruby Rails sensor (candidate)
  -> Collect
       -> reduce durable evidence
       -> behavioral diff
       -> trusted-source attribution
       -> Result v1
  -> Stop -> Teardown
~~~

Ruby remains the Rails-specific runtime sensor. It no longer owns executor lifecycle or comparison policy on the production managed path.

## Compatibility strategy

The existing Ruby reducer/diff stack remains as an oracle:

- `ExecutionReducer`
- `BehavioralDiff`
- `ExecutionPair`
- `script/rundiff_compare_captures.rb`

Go parity tests feed identical captures and changed paths to both implementations and compare normalized JSON structures. We do not delete the Ruby implementation in this slice.

## Semantics to preserve

- durable count/sum/max folding;
- numeric normalization;
- request/worker/async runtime diagnosis;
- optional-signal availability;
- absolute + percentage regression thresholds;
- queue-stage split behavior;
- ALLOW / REVIEW / BLOCK recommendation semantics in the payload;
- explicit source preference;
- only changed-path runtime attribution;
- candidate-only unambiguous runtime source attribution;
- run/scenario identity fencing.

## Non-goals

- changing Request v1 or Result v1;
- changing the public evidence payload;
- replacing Rails instrumentation;
- adding new policy thresholds;
- cgroups/namespaces/eBPF work.

## Acceptance

- managed path does not launch `rundiff_compare_captures.rb`;
- Go output matches Ruby oracle for representative no-regression, regression, optional-signal, durable-evidence, async-stage, and attribution cases;
- existing production fixture remains ALLOW;
- isolated Compose proof remains green;
- full CI remains green.
