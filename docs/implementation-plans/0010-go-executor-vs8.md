# Implementation Plan 0010: Go Executor Vertical Slice 8

## Goal

Move baseline/candidate scenario orchestration and evidence-file ownership from the Ruby pull-request runner into the managed Go executor.

Ruby remains the Rails runtime sensor: it boots the customer application and captures framework-specific evidence. Go decides when each side runs, supplies the exact prepared environment, owns output paths, validates capture JSON, computes changed paths, and returns Result v1.

## Boundary after VS8

~~~text
Go
  prepare / clone
  bootstrap
  subject DB prepare
  service plan + start + ready
  scenario orchestration
    |
    +--> Ruby Rails capture adapter (base)
    +--> Ruby Rails capture adapter (candidate)
    |
  changed-path collection
    |
    +--> Ruby reducer/diff compatibility adapter
    |
  Result v1 validation/submission
  stop / teardown
~~~

The reducer/diff adapter is intentionally temporary. VS8 does not port behavioral policy to Go.

## Capture runtime selection

Go mirrors the existing trusted selection rule:

- if the subject-owned RunDiff Rails markers are present, run `rundiff_capture_subject.rb`;
- otherwise run `rundiff_capture_portable_rails.rb`.

Both adapters execute inside the prepared subject worktree with only the safe host environment plus the role-specific environment already produced by Go bootstrap, subject preparation, and service startup.

## Ownership changes

Go now owns:

- baseline/candidate ordering;
- scenario path loading from strict `rundiff.yml`;
- run/scenario/ref/SHA identity passed to the sensor;
- capture output paths;
- JSON validity checks;
- changed-path collection;
- pair-comparison invocation;
- final Result v1 envelope.

The production agent no longer launches `script/run_cloudflare_executor_bridge.rb`. That script remains only for the Ruby rollback/reference path.

## Safety

- no shell interpolation;
- scenario path comes from the already strict version-1 config parser;
- capture outputs live under the managed execution workspace;
- prepared environments remain role-specific;
- capture failure fails the attempt instead of accepting partial evidence;
- Request v1 and Result v1 are unchanged.

## Acceptance

- Go contract tests prove base + candidate capture orchestration;
- production bridge invokes `rundiff-executor agent` without a Ruby reference command;
- live RunDiff Check reaches ALLOW/BLOCK through the new path;
- scenario phase is journaled as `go-orchestrator`;
- existing CI and isolated Compose proof remain green.
