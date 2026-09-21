# Implementation Plan 0008: Go Executor Vertical Slice 6

## Goal

Move explicit subject-service lifecycle ownership from Ruby into Go:

~~~text
process.start / compose.run
http.wait_ready / tcp.wait_ready
process.stop / compose.stop
~~~

Ruby remains responsible for scenario/capture.

## Planning versus execution

VS6 deliberately separates the service-plan compiler from the service runtime.

The existing Ruby setup-plan model remains the compatibility oracle for compiling repository configuration into typed service operations. A tiny trusted compiler emits only the service subset as JSON. Go owns execution of that typed plan.

This avoids writing a partial YAML parser in the executor and gives us a clean future extraction seam:

~~~text
repository config
  -> service plan compiler
  -> typed service plan JSON
  -> Go ServiceController
~~~

A later slice may move plan compilation into Go or the control plane without changing the ServiceController.

## Process services

Go natively owns:

- dynamic loopback port allocation;
- Ruby/Node process start;
- safe inherited environment;
- stdout/stderr diagnostics;
- HTTP/TCP readiness polling;
- process-group TERM/KILL cleanup;
- Resource Journal service process entries.

## Compose services

The core only defines a ComposeProvider interface.

Compose remains a privileged provider boundary and must not be implemented as unrestricted Docker access inside executor core. The existing isolated Unix-socket Compose provider is the target adapter.

## Ruby handoff

When Go owns services, the reference process receives:

~~~text
RUNDIFF_PREPARED_SERVICES_BY=go
~~~

and role-specific prepared subject env already includes service URLs. Ruby still resolves environment capabilities and performs capture, but skips explicit ServiceExecutor start/readiness/stop.

## Metrics

New Go metrics:

~~~text
phase=start role=base|candidate
phase=ready role=base|candidate
phase=stop role=base|candidate
~~~

## Acceptance

- real process service integration test starts, becomes HTTP ready, and stops;
- service URLs reach prepared subject env;
- Ruby explicit ServiceExecutor is not invoked when Go owns services;
- process tree cleanup is executor-owned;
- production bridge remains ALLOW with no configured services;
- Request v1 / Result v1 unchanged.
