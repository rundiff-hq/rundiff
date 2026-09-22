# Implementation Plan 0012: Go Executor Vertical Slice 10

## Goal

Turn the Rails capture subprocess into an explicit runtime-sensor adapter behind a language-neutral Sensor Protocol v1.

VS9 removed Ruby from comparison policy. The remaining Ruby process is now a sensor: it boots a Rails application, runs one scenario for one role, and emits evidence. VS10 makes that boundary explicit so Node, Go, Python, Java, and Rust sensors can be added without changing the executor lifecycle.

## Target boundary

~~~text
Control Plane
  -> Request v1
Go Executor
  -> runtime sensor registry
       -> rails sensor adapter
            -> subject-owned Rails sensor
            -> portable Rails sensor
       -> future node/go/python/... adapters
  -> Sensor Protocol v1 capture
  -> Go reduction + comparison
  -> Result v1
~~~

## Sensor Protocol v1

The capture artifact remains additive-compatible with the existing evidence shape and gains a required sensor identity envelope:

~~~text
sensor:
  schema_version: "1"
  adapter: rails
  mode: subject_owned_rails | tool_owned_portable_rails
  runtime: ruby
~~~

The protocol validates execution identity, scenario identity, subject/ref/SHA identity, status, measurements, attributions, and durable observations. Unknown fields remain allowed.

## Adapter contract

A Go runtime sensor adapter owns:

- subject detection;
- sensor mode selection;
- executable/argv construction;
- explicit sensor environment;
- capture validation.

The executor owns role orchestration, safe host environment, cancellation, workspaces, changed paths, comparison, and Result v1.

## Non-goals

- porting Rails instrumentation to Go;
- adding a Node sensor in this slice;
- changing Request v1 or Result v1;
- changing Behavioral Diff thresholds;
- changing the public evidence payload beyond additive sensor metadata.

## Acceptance

- managed capture no longer hard-codes Ruby script selection in CapturePair;
- Rails is selected through the sensor registry;
- both Rails modes emit Sensor Protocol v1 identity;
- malformed or mismatched sensor captures fail closed before comparison;
- existing Rails production fixture remains ALLOW;
- Go/Ruby comparison parity remains green;
- isolated Compose proof and full CI remain green.
