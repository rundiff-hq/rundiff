# RFC 0005: Differential mutation evidence

## Status

Proposed design direction for RunDiff, formerly RunDiff. This RFC records product and architecture criteria, not an implementation commitment to any particular mutation engine.

## Context

RunDiff already treats verification as a comparison between a baseline and one or more candidates. Mutation testing adds a second-order question that ordinary test execution cannot answer:

> Would the verification notice if the implementation were wrong?

Traditional mutation systems usually answer this for an entire codebase with a mutation score. RunDiff should instead treat mutation as differential evidence attached to a specific change.

The target question is:

> Did this candidate introduce behavior that the existing verification cannot distinguish from a plausible defect?

## Product insight

Mutation testing should be a first-class evidence type, but it should not define the product.

RunDiff should combine mutation evidence with runtime evidence, tests, contracts, static analysis, specs, and other verification signals. A mutation survivor is evidence to interpret, not an automatic verdict by itself.

The core abstraction should therefore be owned by RunDiff, while language-specific mutation generation can initially be delegated to existing engines.

## Borrow from the Angular / Stryker approach

Our earlier Angular mutation-testing research is useful as an architectural reference rather than as a frontend-only feature.

The useful ideas to borrow are:

1. **Provider integration instead of one hard-coded engine.** Angular/TypeScript can use Stryker, while other ecosystems use their native engines.
2. **Per-test coverage and targeted execution.** Do not rerun an entire test suite for every mutation when the engine can identify the tests that cover a mutation site.
3. **Incremental result reuse.** Persist enough prior evidence to avoid rerunning mutations whose relevant implementation and tests have not changed.
4. **Machine-readable reports.** Treat engine output as structured input to RunDiff, not as the final product report.
5. **Mutation as one verification stage.** Mutation results should flow into the same baseline/candidate comparison and policy system as other evidence.

For Angular/TypeScript specifically, Stryker is the natural first provider candidate. RunDiff should normalize its results rather than reproduce Stryker's UI or scoring model.

## Differential-first model

A whole-repository mutation score is not the primary RunDiff metric.

The preferred model is:

```text
baseline
  -> known mutation sites
  -> known outcomes

candidate
  -> changed semantic scopes
  -> new or changed mutation sites
  -> rerun only affected evidence
  -> compare with baseline
```

The useful outputs are therefore things such as:

- new mutation sites introduced by the candidate;
- mutation sites removed by the candidate;
- previously killed mutants that now survive;
- new surviving mutants in changed semantic scopes;
- changed scopes whose mutation evidence could be reused;
- changed scopes for which verification evidence is missing;
- differential mutation surface area, rather than only a global percentage.

This is closer to the direction explored by `mutate4java` with semantic scope fingerprints and differential mutation surfaces than to a classic repository-wide mutation score.

## Stable semantic identity

Line numbers are not sufficient identity for reusable mutation evidence.

RunDiff should explore stable identities based on a combination of:

- language;
- semantic scope identity, such as class/method/function;
- normalized semantic fingerprint of the scope;
- mutation operator;
- mutation target within that scope.

The exact fingerprinting algorithm is intentionally left open.

Unlike approaches that write manifests into source files, RunDiff should prefer keeping fingerprints and prior evidence outside the subject repository, for example as RunDiff state, CI artifacts, or an optional `.rundiff` cache.

## Incremental evidence reuse

Borrow the useful principle from PIT-style incremental analysis:

```text
same semantic scope
+ same mutation
+ same relevant verification/test
= candidate for result reuse
```

Reuse must be conservative. A provider or RunDiff must rerun evidence when a relevant implementation scope, test, environment contract, mutation operator version, or execution configuration changes.

## Mutation provider boundary

RunDiff should own a provider-neutral mutation protocol.

A provider is responsible for language/tool-specific mechanics such as:

- parsing or instrumenting the subject language;
- discovering mutation sites;
- producing or activating a mutant;
- mapping mutations to relevant tests when supported;
- executing the mutation through the ecosystem's test runner;
- returning structured raw results.

RunDiff is responsible for:

- deciding which changed scopes matter;
- baseline/candidate identity;
- stable RunDiff mutation IDs;
- semantic fingerprints;
- prior-result reuse policy;
- normalization into RunDiff evidence;
- distinguishing new regressions from pre-existing survivors;
- evidence storage;
- policy and verdicts;
- agent-readable feedback;
- GitHub/UI presentation.

The dependency direction must be:

```text
RunDiff mutation evidence contract
        |
        +-- Stryker provider      # Angular / TypeScript / JavaScript
        +-- Mutineer provider     # Ruby
        +-- Mutant provider       # Ruby, optional deeper implementation
        +-- PIT provider          # JVM
        +-- future providers
        +-- optional native RunDiff mutators
```

RunDiff must not expose a third-party engine's schema as its public mutation contract.

## Initial engine strategy

Do not build a complete multi-language mutation engine first.

Suggested sequence:

1. define the RunDiff mutation evidence schema and provider contract;
2. integrate Stryker for Angular/TypeScript as the first frontend reference;
3. integrate Mutineer as a lightweight Ruby reference provider;
4. keep Mutant available as a deeper Ruby comparison/reference implementation;
5. study PIT for coverage-guided execution and history reuse;
6. study `mutate4java` for changed semantic scope fingerprints and differential surface concepts;
7. measure where external engines fail to provide the evidence RunDiff actually needs.

## Internal mutation engine option

A native RunDiff mutation engine may still become valuable, but only for differentiated cases.

The useful version is not "rewrite Mutant/Stryker/PIT for every language". It is a thin, high-signal mutation layer for mutations that existing tools do not express well or that are especially useful to coding agents.

Examples include domain or change-aware mutations such as:

- remove an authorization check;
- remove or alter a transaction boundary;
- drop an idempotency guard;
- change a retry/timeout boundary;
- remove a side-effect or event emission;
- change an API contract branch;
- mutate a changed boolean/boundary condition selected from the PR semantic scope.

For Ruby, Prism makes a small native proof of concept practical. Equivalent language-native parsers can be used later only where the value is demonstrated.

The internal engine should therefore start as an optional provider behind the same contract, not as the core architecture.

## Agent loop

Mutation evidence is especially valuable for agentic development because a survivor can be converted directly into a bounded repair task:

```text
agent changes code
  -> tests pass
  -> RunDiff selects affected mutation sites
  -> provider executes mutations
  -> new survivor appears
  -> RunDiff emits precise evidence
  -> agent strengthens test or implementation
  -> rerun affected evidence
```

The agent should receive the original expression, mutated expression, source scope, relevant tests, baseline status, and survivor status whenever available.

## Candidate evidence shape

Illustrative normalized evidence:

```json
{
  "type": "mutation",
  "id": "mut_1c39...",
  "provider": "mutineer",
  "language": "ruby",
  "scope": "Discount#apply",
  "scope_fingerprint": "8198ab...",
  "operator": "boundary",
  "original": "qty >= 10",
  "mutated": "qty > 10",
  "source": {
    "file": "app/models/discount.rb",
    "line": 42
  },
  "baseline_status": "killed",
  "candidate_status": "survived",
  "differential_status": "regression"
}
```

This schema is illustrative. The public contract should be versioned and engine-neutral.

## Acceptance criteria for the future design

Any mutation architecture adopted by RunDiff / RunDiff should satisfy these criteria:

1. **Provider-neutral** - no public dependency on Mutineer, Stryker, Mutant, PIT, or another engine's native result schema.
2. **Differential-first** - candidate regressions matter more than a global mutation score.
3. **Baseline-aware** - pre-existing survivors must be distinguishable from survivors introduced by the candidate.
4. **Stable evidence identity** - results should survive harmless line movement and formatting changes when semantics are unchanged.
5. **Incremental** - unchanged evidence should be reusable conservatively.
6. **Multi-language** - the core model must not assume Ruby, Angular, JavaScript, or JVM semantics.
7. **Agent-readable** - evidence must be precise enough to drive an automated repair/test-strengthening loop.
8. **Human-readable** - GitHub and UI output must explain the actual behavioral risk, not only show a score.
9. **Composable** - mutation evidence must coexist with runtime, spec, contract, static, and test evidence.
10. **Cost-aware** - providers must support selection, budgets, timeouts, and partial execution because exhaustive mutation can be expensive.
11. **Equivalent-mutant aware** - a survivor is evidence, not automatically a failed policy.
12. **Reproducible** - provider version, operator set, execution environment, and relevant configuration must be part of evidence provenance.
13. **No source pollution required** - RunDiff should not require mutation manifests to be committed into subject source files.
14. **Replaceable providers** - adopting an engine today must not prevent replacing or supplementing it later.

## Direction

The current preferred direction is:

> Own the mutation protocol and differential evidence model; outsource mutation generation first.

Do not make Mutineer, Stryker, Mutant, PIT, or any other engine the architecture. Use them as providers and references.

Only build native RunDiff mutation generation where it produces materially better differential evidence, better agent feedback, lower execution cost, or support for mutation classes that general-purpose engines do not model well.

That keeps RunDiff focused on its differentiator: comparing what a change actually alters and whether the verification system can detect the difference.
