# VS19 - Boxd forked paired-execution spike v1

Status: in progress - provider and first product proof complete; repeated comparative sampling pending

Tracking issues: #210, #217

## Goal

Prove whether Boxd's running-VM fork primitive is useful below the current RunDiff Go executor without changing portable execution semantics.

Target:

~~~text
trusted golden Boxd VM
       |
       +--> fork baseline
       |
       +--> fork candidate
                    |
             exact source refs
                    |
              same scenario
                    |
               Result v1
                    |
             Behavioral Diff
~~~

## Slice A - repository-safe provider seam

Land without Boxd credentials or network access:

1. internal compute.Provider seam with only fork/exec/remove;
2. Boxd CLI adapter;
3. direct argv execution, never shell interpolation;
4. non-zero remote workload exit remains an execution result rather than provider transport failure;
5. pair helper removes the first child if creating the second child fails;
6. pair cleanup attempts both child removals and returns joined cleanup failures;
7. unit tests use a fake command runner.

This slice must not alter Request v1, Result v1, Rails control-plane contracts, or current production dispatch.

### Slice A.1 - headless transport correction

The first live GitHub Actions run proved that Boxd CLI v0.2.20 falls back to
interactive browser authentication in an external CI session even when
`BOXD_API_KEY` is present. The live transport is therefore the official
`@boxd-sh/sdk`, pinned behind a structured JSON bridge.

The correction preserves the same internal `compute.Provider` contract and
the same workload/provider failure distinction. The CLI adapter remains inert
reference code.

For this bounded proof the bridge is process-per-operation. Before any
production promotion, replace that with a long-lived SDK client/session (or a
supported native Go client) so API-key exchange is not repeated per operation.

## Slice B - one-time live provider setup

Operator prerequisites:

~~~text
BOXD_API_KEY available only to the provisioning job
Node 20+ for the pinned Boxd SDK bridge
account quota / credits sufficient for the proof
one trusted golden machine
~~~

Golden machine name for the spike:

~~~text
rundiff-golden-v1
~~~

The exact name is not a durable contract.

Golden setup:

1. create an isolated VM when compatible;
2. install current RunDiff repository/tooling;
3. build apps/executor-go/cmd/rundiff-executor;
4. install subject runtime dependencies needed by the selected dogfood fixture;
5. start reusable services only when their fork semantics are safe;
6. healthcheck;
7. remove any short-lived source/executor credentials before considering it ready.

## Slice C - live fork proof

For one exact execution id:

~~~text
rundiff-golden-v1
  -> fork rundiff-<execution>-base
  -> fork rundiff-<execution>-candidate
~~~

Then:

1. wait until both children are ready;
2. materialize exact baseline SHA in baseline child;
3. materialize exact candidate SHA in candidate child;
4. create independent role-specific mutable application state;
5. execute the same current RunDiff scenario;
6. collect through existing portable evidence/result contracts;
7. return evidence to the existing Behavioral Diff path;
8. remove both children in cleanup.

Do not compare ad-hoc stdout as the product result. The acceptance is a real existing Behavioral Diff.


### Live evidence - 2026-09-29

The first product-level Boxd proof completed successfully in GitHub Actions.

Exact subject pair:

~~~text
repository: rundiff-hq/example-node-express-postgres
baseline:   e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb
candidate:  a1663f54380e3a117989ebc6f1ab8f525f6bed4e
changed:    server.mjs
~~~

Observed portable product result:

~~~text
baseline HTTP:          200
candidate HTTP:         500
decision:               regression
merge_recommendation:   block
blocking finding:       NEW_RUNTIME_ERROR
~~~

The proof used the existing tool-owned Node HTTP sensor, validated both Capture
v1 payloads with `sensor.ValidateCapture`, and passed those captures through
the existing `comparison.Pair` path before constructing and validating
Result v1. No Boxd-specific result schema or ad-hoc product comparison was
introduced.

Observed timings from the successful run:

~~~text
provider.create.golden_ready_ms   2184
subject.golden_prepare_ms        11999
provider.fork_pair_ready_ms       4787
scenario.baseline_capture_ms      7646
scenario.candidate_capture_ms     7709
comparison.behavioral_diff_ms        0
execution.total_ms               36032
provider.cleanup.pair_ms          3315
provider.cleanup.golden_ms        1613
~~~

The same run also re-proved the lower-level copy-on-write isolation path.
These are single-run measurements only and are not evidence of a speedup over
the current hosted executor. Comparative sampling remains required before any
placement or default-provider decision.

## Initial subject

Prefer an already-proven small external subject rather than inventing a new benchmark.

Candidate:

~~~text
rundiff-hq/example-node-express-postgres
~~~

If the current Rails dogfood subject gives stronger parity with existing timing measurements, use that instead.

The chosen subject must already have a known baseline/candidate behavioral change so the provider experiment does not become a second product experiment.

## Measurements

Record machine-readable timing for:

~~~text
provider.fork.base
provider.fork.candidate
provider.ready.base
provider.ready.candidate
source.materialize.base
source.materialize.candidate
subject.prepare.base
subject.prepare.candidate
scenario.base
scenario.candidate
provider.cleanup.base
provider.cleanup.candidate
execution.total
~~~

Also record:

- provider identity;
- machine shape;
- region;
- isolation mode;
- actual observed cost if Boxd exposes it;
- source revisions;
- whether the golden parent was cold, running, suspended, or hibernated before the proof.

Do not put provider-specific timing into Result v1 unless later RFC work makes that portable contract explicit.

## Comparison

Compare at least five alternating samples against the current hosted path where practical.

Do not infer a speedup from one warm Boxd sample and one cold GitHub Actions sample.

Separate:

~~~text
provider provisioning
dependency/bootstrap
subject mutable-state preparation
scenario execution
evidence collection
cleanup
~~~

The important metric is end-to-end saved work, not the advertised fork latency.

## Correctness checks

The live proof must demonstrate:

- baseline/candidate exact revisions are different where expected;
- mutable DB/service writes in baseline are absent from candidate;
- both children inherit the intended trusted warm state;
- candidate regression still becomes the same existing finding/outcome;
- provider failure maps to infrastructure failure;
- customer workload failure is not mislabeled provider failure;
- cleanup runs after failure;
- a failed second fork does not leak the first fork;
- cancellation can terminate/remove provider resources before production adoption.

## Security checks

- no GitHub App private key in the golden VM;
- no webhook secret in the golden VM;
- no broad organization token in either child;
- repository capability remains short lived and repository scoped;
- Boxd credentials are available only to the provisioning layer;
- provider stderr/stdout are not blindly persisted into durable customer evidence;
- isolated mode semantics are verified before relying on them.

## Rollback

Slice A is inert unless explicitly called.

If the live provider is unhealthy:

~~~text
placement excludes boxd
-> current GitHub-hosted / other provider path remains unchanged
~~~

No Request/Result migration or data rollback is required.

## Exit criteria

The spike is successful when:

1. the real existing behavioral proof runs through two forked Boxd children;
2. Result/evidence semantics remain unchanged;
3. cleanup is deterministic;
4. repeated samples show a material preparation/cost advantage or a clearly valuable operational property;
5. the data is sufficient to decide whether to build the next provider integration slice.

If these criteria are not met, keep RFC 0013 as research and do not promote Boxd into normal placement.
