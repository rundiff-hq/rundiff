# Sensor Protocol v1

Sensor Protocol v1 is the language-neutral boundary between the Go executor and runtime-specific evidence sensors.

A sensor executes one already-prepared subject role and emits one capture JSON document. The executor, not the sensor, owns baseline/candidate orchestration, cancellation, workspaces, changed-path discovery, comparison, policy handoff, and Result v1.

## Compatibility rules

- `sensor.schema_version` is exactly `"1"`.
- Unknown fields are allowed.
- Sensor metadata is additive to the historical capture payload.
- `run_id`, `scenario_id`, `ref`, and `sha` are fenced against the exact executor assignment before comparison.
- Runtime-specific sensors may emit richer lifecycle and durable evidence fields.
- A sensor must never receive control-plane credentials through its environment.
- Rails is the first adapter; Node, Go, Python, Java, and Rust can implement the same boundary later.
