import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  validateExecutorRequest,
  validateExecutorResult,
} from "../src/domain/executor";

const fixture = (name: string): unknown =>
  JSON.parse(
    readFileSync(
      new URL(`../../../protocol/executor/v1/fixtures/${name}`, import.meta.url),
      "utf8",
    ),
  );

test("Request v1 golden fixture is accepted without semantic drift", () => {
  const payload = fixture("request.json");
  assert.deepEqual(validateExecutorRequest(payload), payload);
});

test("Result v1 golden fixtures are accepted without semantic drift", () => {
  for (const name of [
    "result-allow.json",
    "result-block.json",
    "result-failure.json",
  ]) {
    const payload = fixture(name);
    assert.deepEqual(validateExecutorResult(payload), payload);
  }
});

test("canonical schemas declare protocol v1", () => {
  for (const name of ["request.schema.json", "result.schema.json"]) {
    const schema = JSON.parse(
      readFileSync(
        new URL(`../../../protocol/executor/v1/${name}`, import.meta.url),
        "utf8",
      ),
    );
    assert.equal(schema.properties.schema_version.const, "1");
  }
});
