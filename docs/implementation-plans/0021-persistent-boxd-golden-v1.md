# Implementation Plan 0021: Persistent Boxd Golden Environments v1

Status: in progress

Tracking issue: #222

## Goal

Stop rebuilding trusted Boxd preparation state for every RunDiff execution.

The BOXD3 benchmark measured the current proof path at:

~~~text
hosted managed Go median   2.417 s
Boxd proof median         39.738 s
~~~

The largest avoidable Boxd setup component was repeated golden preparation:

~~~text
create golden      ~2.054 s median
prepare golden    ~11.522 s median
~~~

This slice makes golden preparation a reusable lifecycle rather than per-execution work.

## Identity

A golden environment is keyed by immutable, non-secret preparation identity:

~~~text
schema version
provider
base image
repository
trusted source/base identity
RunDiff tool revision
runtime/toolchain identity
dependency lock digest
service topology digest
~~~

The canonical JSON representation is SHA-256 hashed.

The machine name is a bounded deterministic prefix:

~~~text
rundiff-golden-<fingerprint-prefix>
~~~

The fingerprint must never contain or depend on:

- GitHub App private keys;
- webhook secrets;
- executor/control-plane tokens;
- short-lived repository capabilities;
- customer mutable runtime state.

## Lifecycle

~~~text
Ensure(spec)
  |
  +--> provider.Get(deterministic name)
          |
          +--> ready marker exists -> REUSE
          |
          +--> marker absent -> remove invalid machine
          |
          +--> NotFound -> create isolated machine
                              |
                              v
                            prepare
                              |
                              v
                         ready marker
~~~

A transport/auth/provider lookup error is not treated as NotFound and must not silently create a replacement.

If preparation or ready marking fails, the newly created machine is removed.

## Ready marker

The manager writes a provider-internal readiness marker after successful trusted preparation:

~~~text
/var/lib/rundiff/golden/<full-fingerprint>.ready
~~~

The deterministic name plus full fingerprint marker protects reuse from partially prepared or manually replaced machines.

## Boxd transport

The pinned `@boxd-sh/sdk` supports `machines.get(id-or-name)` and typed
`NotFoundError`.

The JSON bridge maps only typed NotFound into a successful structured
`notFound` response. Authentication, permission, quota, transport and other
provider failures remain errors.

## Live proof

The opt-in proof must:

1. remove any stale test machine for the exact test fingerprint;
2. call `Ensure` once and prepare one isolated machine;
3. call `Ensure` again with the same spec;
4. prove the second call returns the same machine with `Reused=true`;
5. prove preparation ran exactly once;
6. prove prepared state remains present;
7. remove the test machine after the proof.

The proof cleans up because its purpose is lifecycle validation, not leaving a
billable benchmark machine resident. Production callers of `GoldenManager`
do not remove a healthy golden after each execution.

## Next slices

This slice deliberately does not yet optimize:

- process-per-operation SDK bridge;
- sequential pair fork;
- running PostgreSQL inheritance;
- hibernate/wake lifecycle;
- golden refresh scheduling;
- concurrent Ensure races.

Those are BOXD4 follow-up slices after persistent identity/reuse is proven.

## Acceptance

- deterministic provider-independent fingerprint tests;
- SDK get-by-name with typed NotFound;
- reuse does not rerun preparation;
- invalid golden refresh is deterministic;
- failed preparation leaves no machine;
- live Boxd reuse proof;
- normal CI remains green;
- no Request v1 / Result v1 changes.
