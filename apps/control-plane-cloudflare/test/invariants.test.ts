import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { generateKeyPairSync } from "node:crypto";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { D1GitHubRepository } from "../src/adapters/d1/github-repository";
import { D1ExecutionRepository } from "../src/adapters/d1/execution-repository";
import { D1ReviewRepository } from "../src/adapters/d1/review-repository";
import { GitHubClient, githubPrivateKeyPkcs8 } from "../src/adapters/github/client";
import {
  verifyWebhook,
  parsePullRequest,
  type PullRequestIdentity,
} from "../src/domain/github";

const identity: PullRequestIdentity = {
  deliveryId: "delivery-1",
  repository: "demo/shop",
  repositoryId: 1,
  pullRequestNumber: 42,
  installationId: 7,
  baselineSha: "a".repeat(40),
  candidateSha: "b".repeat(40),
  baselineRef: "main",
  candidateRef: "fix",
  updatedAt: "2026-09-20T00:00:00Z",
};
const result = {
  schema_version: "1" as const,
  status: "succeeded" as const,
  payload: { result: { merge_recommendation: "block" } },
  error_class: null,
  error_message: null,
};

test("webhook verifies exact raw bytes and rejects malformed signatures", async () => {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("test-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = Buffer.from(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode("{}")),
  ).toString("hex");
  assert.equal(await verifyWebhook("{}", `sha256=${sig}`, "test-secret"), true);
  assert.equal(
    await verifyWebhook("{ }", `sha256=${sig}`, "test-secret"),
    false,
  );
  assert.equal(await verifyWebhook("{}", "sha256=bad", "test-secret"), false);
});
test("pull request identity is exact and forks are rejected", () => {
  const payload = {
    action: "opened",
    repository: { id: 1, full_name: "demo/shop" },
    installation: { id: 7 },
    pull_request: {
      number: 42,
      state: "open",
      updated_at: identity.updatedAt,
      base: {
        sha: identity.baselineSha,
        ref: "main",
        repo: { full_name: "demo/shop" },
      },
      head: {
        sha: identity.candidateSha,
        ref: "fix",
        repo: { full_name: "demo/shop" },
      },
    },
  };
  assert.deepEqual(parsePullRequest(payload, "delivery-1"), identity);
  assert.equal(
    parsePullRequest({ ...payload, action: "closed" }, "delivery-1"),
    null,
  );
  payload.pull_request.head.repo.full_name = "other/fork";
  assert.throws(() => parsePullRequest(payload, "delivery-1"));
});
test("GitHub transport is invoked without the GitHubClient receiver", async () => {
  let receiver: unknown = "not-called";
  const transport = (async function (this: unknown) {
    receiver = this;
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;

  const client = new GitHubClient("installation-token", transport);
  assert.deepEqual(await client.request("/test"), { ok: true });
  assert.equal(receiver, undefined);
});

test("GitHub App RSA keys accept PKCS#1 and PKCS#8 PEM formats", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  for (const type of ["pkcs1", "pkcs8"] as const) {
    const pem = privateKey.export({ format: "pem", type }).toString();
    const imported = await crypto.subtle.importKey(
      "pkcs8",
      githubPrivateKeyPkcs8(pem),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    assert.equal(imported.type, "private");
  }
});
test("real D1 dedupe, exact claim, result retries, supersede and finalization fences", async (t) => {
  const mf = new Miniflare(
    convertV4MiniflareOptions({
      name: "test",
      modules: true,
      script: 'export default {fetch(){return new Response("test")}}',
      compatibilityDate: "2026-09-20",
      d1Databases: ["DB"],
    }),
  );
  t.after(() => mf.dispose());
  const db = await mf.getD1Database("DB");
  for (const file of readdirSync("migrations").sort())
    for (const sql of readFileSync(`migrations/${file}`, "utf8")
      .split(";")
      .filter((x) => x.trim()))
      await db.prepare(sql).run();
  const github = new D1GitHubRepository(db as unknown as D1Database);
  const executions = new D1ExecutionRepository(db as unknown as D1Database);
  const reviews = new D1ReviewRepository(db as unknown as D1Database);
  const first = await github.accept(identity, "digest-1", "orders.show", 1800);
  assert.equal(
    (await github.accept(identity, "digest-1", "orders.show", 1800)).reviewId,
    first.reviewId,
  );
  await assert.rejects(
    github.accept(identity, "changed", "orders.show", 1800),
    /conflict/,
  );
  assert.equal(
    await executions.claimMatching({
      ...identity,
      baselineSha: "c".repeat(40),
      now: new Date().toISOString(),
    }),
    null,
  );
  const claimed = await executions.claimMatching({
    ...identity,
    now: new Date().toISOString(),
  });
  assert.equal(claimed?.id, first.executionId);
  const input = {
    executionId: first.executionId,
    attemptNumber: 1,
    result,
    digest: "result-1",
    now: new Date().toISOString(),
  };
  assert.equal(
    await executions.recordResult({ ...input, attemptNumber: 2 }),
    "not_live",
  );
  assert.deepEqual(
    (
      await Promise.all([
        executions.recordResult(input),
        executions.recordResult(input),
      ])
    ).sort(),
    ["accepted", "duplicate"],
  );
  assert.equal(
    await executions.recordResult({ ...input, digest: "conflict" }),
    "conflict",
  );
  const second = await github.accept(
    {
      ...identity,
      deliveryId: "delivery-2",
      candidateSha: "c".repeat(40),
      updatedAt: "2026-09-20T00:01:00Z",
    },
    "digest-2",
    "orders.show",
    1800,
  );
  assert.equal(await github.current(first.executionId), false);
  await executions.finalize(
    first.executionId,
    1,
    "BLOCK",
    result,
    new Date().toISOString(),
  );
  assert.equal((await reviews.get(first.reviewId))?.status, "superseded");
  assert.equal((await reviews.get(first.reviewId))?.decision, null);
  await executions.finalize(
    second.executionId,
    2,
    "ALLOW",
    result,
    new Date().toISOString(),
  );
  assert.equal((await reviews.get(second.reviewId))?.decision, null);
  await executions.finalize(
    second.executionId,
    1,
    "BLOCK",
    result,
    new Date().toISOString(),
  );
  await executions.finalize(
    second.executionId,
    1,
    "INFRA_FAILURE",
    {},
    new Date().toISOString(),
  );
  assert.equal((await reviews.get(second.reviewId))?.decision, "BLOCK");
  const stale = await github.accept(
    { ...identity, deliveryId: "late-old-delivery" },
    "digest-3",
    "orders.show",
    1800,
  );
  assert.equal(await github.current(stale.executionId), false);
  assert.equal(await github.current(second.executionId), true);
});


test("exact attempts use renewable leases and reject late results after cancellation", async (t) => {
  const mf = new Miniflare(
    convertV4MiniflareOptions({
      name: "lease-test",
      modules: true,
      script: 'export default {fetch(){return new Response("test")}}',
      compatibilityDate: "2026-09-20",
      d1Databases: ["DB"],
    }),
  );
  t.after(() => mf.dispose());
  const db = await mf.getD1Database("DB");
  for (const file of readdirSync("migrations").sort())
    for (const sql of readFileSync(`migrations/${file}`, "utf8")
      .split(";")
      .filter((x) => x.trim()))
      await db.prepare(sql).run();

  const reviews = new D1ReviewRepository(db as unknown as D1Database);
  const executions = new D1ExecutionRepository(db as unknown as D1Database);
  const now = "2026-09-21T12:00:00.000Z";
  const review = await reviews.create({
    id: "review-lease",
    projectId: "demo/shop",
    scenarioId: "orders.show",
    baselineSha: "a".repeat(40),
    candidateSha: "b".repeat(40),
    workflowInstanceId: "workflow-lease",
    now,
  });
  const execution = await executions.create({
    reviewId: review.id,
    repository: "demo/shop",
    pullRequestNumber: 42,
    scenarioId: "orders.show",
    baselineSha: "a".repeat(40),
    candidateSha: "b".repeat(40),
    baselineRef: "main",
    candidateRef: "fix",
    candidateRepository: "demo/shop",
    now,
  });

  assert.equal(
    (
      await executions.resolveMatching({
        repository: "demo/shop",
        pullRequestNumber: 42,
        baselineSha: "a".repeat(40),
        candidateSha: "b".repeat(40),
        now,
      })
    )?.id,
    execution.id,
  );

  const claimed = await executions.claimExact({
    executionId: execution.id,
    attemptNumber: 1,
    leaseSeconds: 90,
    now,
  });
  assert.equal(claimed?.status, "claimed");
  assert.equal(claimed?.heartbeatAt, now);
  assert.equal(claimed?.leaseExpiresAt, "2026-09-21T12:01:30.000Z");
  assert.equal(
    await executions.claimExact({
      executionId: execution.id,
      attemptNumber: 1,
      leaseSeconds: 90,
      now,
    }),
    null,
  );

  const heartbeat = await executions.heartbeat({
    executionId: execution.id,
    attemptNumber: 1,
    leaseSeconds: 90,
    now: "2026-09-21T12:00:30.000Z",
  });
  assert.deepEqual(heartbeat, {
    state: "live",
    leaseExpiresAt: "2026-09-21T12:02:00.000Z",
  });

  assert.equal(
    await executions.cancel({
      executionId: execution.id,
      attemptNumber: 1,
      reason: "operator_cancelled",
      now: "2026-09-21T12:00:40.000Z",
    }),
    "cancelled",
  );
  assert.equal((await reviews.get(review.id))?.status, "cancelled");
  assert.deepEqual(
    await executions.heartbeat({
      executionId: execution.id,
      attemptNumber: 1,
      leaseSeconds: 90,
      now: "2026-09-21T12:00:50.000Z",
    }),
    { state: "cancelled", cancellationReason: "operator_cancelled" },
  );
  assert.equal(
    await executions.recordResult({
      executionId: execution.id,
      attemptNumber: 1,
      result,
      digest: "late-result",
      now: "2026-09-21T12:00:55.000Z",
    }),
    "not_live",
  );
});


test("platform installation token dispatches exact executor workflow", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const calls: Array<{ path: string; method: string; body: unknown; authorization: string | null }> = [];

  const transport = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    calls.push({
      path: url.pathname,
      method: init?.method ?? "GET",
      body,
      authorization: new Headers(init?.headers).get("authorization"),
    });

    if (url.pathname === "/repos/rundiff-hq/rundiff/installation") {
      return Response.json({ id: 99 });
    }
    if (url.pathname === "/app/installations/99/access_tokens") {
      assert.deepEqual(body, {
        repositories: ["rundiff"],
        permissions: { actions: "write" },
      });
      return Response.json({ token: "platform-installation-token" });
    }
    if (
      url.pathname ===
      "/repos/rundiff-hq/rundiff/actions/workflows/rundiff-executor-bridge.yml/dispatches"
    ) {
      assert.equal(
        new Headers(init?.headers).get("authorization"),
        "Bearer platform-installation-token",
      );
      assert.deepEqual(body, {
        ref: "main",
        inputs: {
          execution_id: "exec-1",
          attempt_number: "1",
          repository: "customer/shop",
          candidate_sha: "b".repeat(40),
        },
      });
      return new Response(null, { status: 204 });
    }

    return new Response("not found", { status: 404 });
  }) as typeof fetch;

  const client = await GitHubClient.repositoryInstallation(
    {
      RUNDIFF_GITHUB_APP_ID: "123",
      RUNDIFF_GITHUB_APP_PRIVATE_KEY: pem,
    },
    "rundiff-hq/rundiff",
    { actions: "write" },
    transport,
  );

  await client.dispatchWorkflow(
    "rundiff-hq/rundiff",
    "rundiff-executor-bridge.yml",
    "main",
    {
      execution_id: "exec-1",
      attempt_number: "1",
      repository: "customer/shop",
      candidate_sha: "b".repeat(40),
    },
  );

  assert.deepEqual(
    calls.map((call) => [call.method, call.path]),
    [
      ["GET", "/repos/rundiff-hq/rundiff/installation"],
      ["POST", "/app/installations/99/access_tokens"],
      [
        "POST",
        "/repos/rundiff-hq/rundiff/actions/workflows/rundiff-executor-bridge.yml/dispatches",
      ],
    ],
  );
});
