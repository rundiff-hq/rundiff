# Implementation Plan 0006: Go Executor Vertical Slice 4

## Goal

Move Rails dependency bootstrap ownership from the Ruby reference runtime into the managed Go executor while preserving frozen Request v1 / Result v1 and the existing Ruby behavioral oracle.

## Scope

VS4 implements Go-native `ruby.bundle` bootstrap for the current production Rails path:

- validate `Gemfile` and committed `Gemfile.lock`;
- verify Ruby major/minor compatibility;
- honor the Bundler version pinned by `BUNDLED WITH`;
- execute `bundle check` and frozen `bundle install` when required;
- share the bundle cache between baseline and candidate when lockfiles are identical;
- reject lockfile mutation;
- pass only the prepared runtime environment into the Ruby oracle;
- record separate Go bootstrap timing for base and candidate.

JavaScript dependency bootstrap stays on the Ruby path until the Go executor has an explicit typed package-manager capability model. The current production fixture has no JavaScript root manifest, so this is a real vertical slice rather than a partial execution of the same subject.

## Build boundary

The current setup plan does not contain an application Build operation. It contains:

~~~text
bootstrap:
  ruby.bundle
  optional javascript.dependencies

prepare:
  rails.db_prepare
~~~

VS4 therefore does not invent a fake Build step.

The Go executor exposes a `Builder` boundary and retains the `Build` lifecycle phase. A future typed build operation can attach there without changing Request v1 / Result v1 or collapsing dependency bootstrap into build semantics.

## Security

Go-native bootstrap uses a sanitized host environment equivalent to the Ruby subject command boundary.

Allowed inherited keys are limited to:

~~~text
PATH
HOME
TMPDIR
LANG
LC_ALL
LC_CTYPE
SSL_CERT_FILE
SSL_CERT_DIR
~~~

GitHub App tokens, bridge tokens, webhook secrets, SSH agent sockets, and arbitrary host environment are not forwarded to `gem` or `bundle`.

VS4 intentionally fails closed when subject UID/GID isolation is configured because Go-native credential switching is not implemented in this slice. The Ruby/bootstrap path remains the compatibility path for that capability until the native host isolation backend lands.

## Runtime handoff

Go sends role-specific bootstrap environments to the trusted Ruby reference process as JSON:

~~~text
RUNDIFF_PREPARED_BASELINE_RUNTIME_ENV_JSON
RUNDIFF_PREPARED_CANDIDATE_RUNTIME_ENV_JSON
~~~

The Ruby lifecycle still compiles its typed setup plan for environment/services, but skips its Bootstrap executor when a prepared runtime environment exists.

## Measurement

The existing shared phase metrics stream now produces comparable samples:

~~~text
implementation=go phase=bootstrap role=base
implementation=go phase=bootstrap role=candidate
~~~

The paired benchmark uses:

~~~text
Ruby mode:
  Ruby owns Clone + Bootstrap

Go mode:
  Go owns Clone + Bootstrap
~~~

with alternating order on the same runner.

## Acceptance

- Go-native Ruby bootstrap passes unit and integration tests;
- secret host env is not forwarded;
- baseline/candidate with the same lockfile share one bundle cache;
- Ruby bootstrap does not run when Go runtime env is supplied;
- role-specific runtime env reaches the Ruby reference process;
- Go emits base/candidate bootstrap duration metrics;
- exact lease/heartbeat/cancellation/result fencing remains unchanged;
- live bridge ends in RunDiff ALLOW;
- Request v1 / Result v1 remain byte-contract compatible.
