# Implementation Plan 0009: Go Executor Vertical Slice 7

## Goal

Remove the Ruby subprocess from the Go-owned service planning path.

VS6 moved service execution, readiness, and cleanup into Go, but each role still spawned Ruby to load `rundiff.yml` and compile explicit service steps. VS7 makes that boundary native.

## Execution split

~~~text
Go
  rundiff.yml parse + strict validation
  service plan compile
  process.start / compose.run
  http.wait_ready / tcp.wait_ready
  |
  v
Ruby
  scenario / capture
  |
  v
Go
  process.stop / compose.stop
~~~

## Configuration contract

Go validates the existing version-1 configuration vocabulary rather than introducing a second public format:

- top-level `version`, `scenario`, `subject`;
- persistence and setup mode;
- process services;
- compose services;
- HTTP/TCP readiness;
- duplicate service names and `url_env` values;
- repository-relative entrypoint/manifest paths;
- unknown YAML fields fail closed.

The implementation uses `gopkg.in/yaml.v3` with known-field decoding. The module is pinned by version and checksum.

## Parity oracle

The Ruby compiler remains in the repository as a compatibility oracle. A Go test compiles the same explicit process + Compose configuration through both implementations and requires identical typed service-plan output.

The native compiler intentionally emits only service phases. Rails framework detection, bootstrap, and subject preparation already have their own Go-owned boundaries from VS4/VS5.

## Measurement

VS6 production proof showed empty-plan Go `start` at approximately:

~~~text
base       215 ms
candidate   76 ms
~~~

That phase still included Ruby process startup for plan compilation. VS7 removes that subprocess. The next production proof compares the same `start` phase on the same GitHub runner topology.

This is not presented as a general Go-vs-Ruby language benchmark. It measures one migrated RunDiff boundary.

## Acceptance

- current `rundiff.yml` compiles natively;
- process + Compose plans match the Ruby oracle;
- malformed/unknown configuration fails closed;
- production agent uses `NativeCompiler`;
- no Ruby service-plan subprocess is required by Go-owned Start/Ready/Stop;
- Request v1 / Result v1 remain unchanged;
- live bridge and isolated Compose proof remain green.
