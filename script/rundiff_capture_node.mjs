import fs from "node:fs";
import { performance } from "node:perf_hooks";
import { randomUUID } from "node:crypto";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};

const baseURL = required("RUNDIFF_SCENARIO_BASE_URL").replace(/\/$/, "");
const path = required("RUNDIFF_SCENARIO_PATH");
const startedCPU = process.cpuUsage();
const started = performance.now();

let response;
let responseBytes = 0;
let failure;
try {
  response = await fetch(baseURL + path, { method: "POST" });
  responseBytes = (await response.arrayBuffer()).byteLength;
} catch (error) {
  failure = error;
}
const elapsed = performance.now() - started;
const cpu = process.cpuUsage(startedCPU);
const passed = !failure && response.status >= 200 && response.status <= 299;

const payload = {
  sensor: {
    schema_version: process.env.RUNDIFF_SENSOR_SCHEMA_VERSION || "1",
    adapter: process.env.RUNDIFF_SENSOR_ADAPTER || "node",
    mode: process.env.RUNDIFF_CAPTURE_RUNTIME || "tool_owned_node_http",
    runtime: process.env.RUNDIFF_SENSOR_RUNTIME || "node"
  },
  id: required("RUNDIFF_EXECUTION_LABEL"),
  execution_id: randomUUID(),
  run_id: required("RUNDIFF_RUN_ID"),
  scenario_id: required("RUNDIFF_SCENARIO_ID"),
  subject: required("RUNDIFF_SUBJECT"),
  ref: required("RUNDIFF_EXECUTION_LABEL"),
  sha: required("RUNDIFF_EXECUTION_SHA"),
  status: passed ? "passed" : "failed",
  http_status: response?.status ?? null,
  correlation_confirmed: false,
  async_correlation_confirmed: false,
  measurements: {
    duration_ms: Number(elapsed.toFixed(1)),
    process_cpu_ms: Number(((cpu.user + cpu.system) / 1000).toFixed(1)),
    response_bytes: responseBytes,
    errors: passed ? 0 : 1
  },
  attributions: {},
  durable_observations: [],
  application_job_executions: [],
  lifecycle: {
    capture_runtime: "tool_owned_node_http",
    evidence_scope: "http_black_box"
  }
};

fs.writeFileSync(required("RUNDIFF_OUTPUT"), JSON.stringify(payload, null, 2));
process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
if (failure) throw failure;
