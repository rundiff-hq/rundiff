# Implementation Plan 0013: Go Executor Vertical Slice 11

## Goal

Prove Sensor Protocol v1 with a second real runtime: Node.js.

VS11 makes the managed executor runtime-aware end to end. Rails continues through Ruby/Bundler + Rails DB preparation. A pure Node subject goes through deterministic npm bootstrap, explicit Node service lifecycle, and a tool-owned Node HTTP sensor. Both emit the same Sensor Capture v1 and enter the same Go comparison path.

## Boundary

~~~text
Go Executor
  -> runtime-aware bootstrap
       Rails -> RubyBundle
       Node  -> npm ci
  -> runtime-aware subject prepare
       Rails -> RailsDB
       Node  -> no database preparation
  -> service plan / readiness
  -> sensor registry
       Rails -> Ruby sensor
       Node  -> Node HTTP sensor
  -> Sensor Protocol v1
  -> Go comparison
  -> Result v1
~~~

## Node v1 contract

A pure Node subject is detected by `package.json` without Rails `config/environment.rb`.
The first Node slice requires:

- committed `package-lock.json`;
- exactly one explicit Node process service in `rundiff.yml`;
- that service's `url_env` becomes the scenario base URL;
- `scenario.path` remains the request path.

The tool-owned Node sensor uses Node's built-in HTTP/fetch runtime and writes Sensor Protocol v1 evidence.

## Evidence honesty

Signals a sensor cannot observe are omitted, not reported as zero. The Go comparator treats a signal as unavailable unless both captures provide it. This prevents the Node black-box sensor from claiming knowledge of SQL/job/email/outbound-network counts it does not instrument yet.

## Acceptance

- existing Rails managed path remains green;
- pure Node subject does not enter RubyBundle or RailsDB;
- npm bootstrap is deterministic and lockfile-preserving;
- Node service starts/readies/stops under Go;
- Node sensor emits valid Sensor Capture v1;
- Node baseline/candidate pair reaches Go comparison;
- a deliberate Node HTTP failure is visible as an error/status change;
- full CI and production Rails bridge remain green.
