import { D1GitHubRepository } from "../adapters/d1/github-repository";
import { GitHubClient } from "../adapters/github/client";
import { parsePullRequest, verifyWebhook } from "../domain/github";
import { Hono } from "hono";

import { D1ExecutionRepository } from "../adapters/d1/execution-repository";
import { D1ReviewRepository } from "../adapters/d1/review-repository";
import { validateExecutorResult } from "../domain/executor";
import type { Env } from "./env";
export { BehavioralReviewWorkflow } from "./workflows/behavioral-review";

type CreateSpikeReviewBody = {
  repository: string;
  pull_request_number: number;
  scenario_id: string;
  baseline_sha: string;
  candidate_sha: string;
  baseline_ref?: string;
  candidate_ref?: string;
  candidate_repository?: string;
};

type ClaimBody = {
  repository: string;
  pull_request_number: number;
  baseline_sha: string;
  candidate_sha: string;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/api/health", (c) =>
  c.json({ ok: true, service: "rundiff-control-plane" }),
);

app.get("/api/ready", async (c) => {
  await c.env.DB.prepare("SELECT 1").first();
  return c.json({ ok: true, d1: "ready" });
});

app.post("/api/github/webhooks", async (c) => {
  if (!c.env.RUNDIFF_GITHUB_WEBHOOK_SECRET)
    return c.json({ error: "GitHub webhook is not configured" }, 503);
  const raw = await c.req.text();
  if (
    !(await verifyWebhook(
      raw,
      c.req.header("x-hub-signature-256"),
      c.env.RUNDIFF_GITHUB_WEBHOOK_SECRET,
    ))
  )
    return c.json({ error: "invalid signature" }, 401);
  if (c.req.header("x-github-event") !== "pull_request")
    return c.json({ status: "ignored" }, 202);
  const deliveryId = c.req.header("x-github-delivery");
  if (!deliveryId || !/^[a-zA-Z0-9-]{1,100}$/.test(deliveryId))
    return c.json({ error: "invalid delivery ID" }, 422);
  let identity;
  try {
    identity = parsePullRequest(JSON.parse(raw), deliveryId);
  } catch {
    return c.json({ error: "invalid or unsupported pull request" }, 422);
  }
  if (!identity) return c.json({ status: "ignored" }, 202);
  if (
    !c.env.RUNDIFF_GITHUB_APP_ID ||
    !c.env.RUNDIFF_GITHUB_APP_PRIVATE_KEY ||
    !c.env.RUNDIFF_GITHUB_SCENARIO_ID
  )
    return c.json(
      { error: "GitHub App and proof scenario are not configured" },
      503,
    );
  const github = await GitHubClient.installation(
    c.env,
    identity.installationId,
    identity.repositoryId,
  );
  if (
    !(await github.current(
      identity.repository,
      identity.pullRequestNumber,
      identity.candidateSha,
    ))
  )
    return c.json({ status: "stale" }, 202);
  const repo = new D1GitHubRepository(c.env.DB);
  const accepted = await repo.accept(
    identity,
    await canonicalDigest(JSON.parse(raw)),
    c.env.RUNDIFF_GITHUB_SCENARIO_ID,
    Number(c.env.RUNDIFF_EXECUTOR_TIMEOUT_SECONDS ?? 1800),
  );
  if (await repo.current(accepted.executionId)) {
    // Idempotent recovery when the database commit succeeded but Workflow creation did not.
    let exists = false;
    try {
      const instance = await c.env.REVIEW_WORKFLOW.get(accepted.reviewId);
      await instance.status();
      exists = true;
    } catch {
      /* Workflow.get throws when the instance does not exist. */
    }
    if (!exists)
      await c.env.REVIEW_WORKFLOW.create({
        id: accepted.reviewId,
        params: {
          reviewId: accepted.reviewId,
          executionId: accepted.executionId,
          attemptNumber: 1,
        },
      });
  }
  return c.json(accepted, 202);
});

app.post("/api/spike/reviews", async (c) => {
  if (
    !(await tokenAuthorized(
      c.req.header("authorization"),
      c.env.RUNDIFF_SPIKE_TOKEN,
    ))
  ) {
    return c.json({ error: "unauthorized" }, 401);
  }
  const body = await c.req.json<CreateSpikeReviewBody>();

  if (
    !body.repository ||
    !Number.isInteger(body.pull_request_number) ||
    !body.scenario_id ||
    !body.baseline_sha ||
    !body.candidate_sha
  ) {
    return c.json({ error: "missing required review identity" }, 422);
  }

  const id = crypto.randomUUID();
  const workflowInstanceId = id;
  const now = new Date().toISOString();
  const reviews = new D1ReviewRepository(c.env.DB);
  const executions = new D1ExecutionRepository(c.env.DB);

  const review = await reviews.create({
    id,
    projectId: body.repository,
    scenarioId: body.scenario_id,
    baselineSha: body.baseline_sha,
    candidateSha: body.candidate_sha,
    workflowInstanceId,
    now,
  });

  const execution = await executions.create({
    reviewId: id,
    repository: body.repository,
    pullRequestNumber: body.pull_request_number,
    scenarioId: body.scenario_id,
    baselineSha: body.baseline_sha,
    candidateSha: body.candidate_sha,
    baselineRef: body.baseline_ref ?? "main",
    candidateRef: body.candidate_ref ?? `pull/${body.pull_request_number}/head`,
    candidateRepository: body.candidate_repository ?? body.repository,
    now,
  });

  await c.env.REVIEW_WORKFLOW.create({
    id: workflowInstanceId,
    params: {
      reviewId: id,
      executionId: execution.id,
      attemptNumber: execution.attemptNumber,
    },
  });

  return c.json({ review, execution: execution.request }, 201);
});

app.get("/api/reviews/:id", async (c) => {
  if (
    !(await tokenAuthorized(
      c.req.header("authorization"),
      c.env.RUNDIFF_SPIKE_TOKEN,
    ))
  ) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const review = await new D1ReviewRepository(c.env.DB).get(c.req.param("id"));
  return review
    ? c.json({ review })
    : c.json({ error: "review not found" }, 404);
});

app.post("/api/execution-bridges/github-actions/resolve", async (c) => {
  if (
    !(await tokenAuthorized(
      c.req.header("authorization"),
      c.env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN,
    ))
  ) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const body = await c.req.json<ClaimBody>();
  if (
    !body.repository ||
    !Number.isInteger(body.pull_request_number) ||
    !body.baseline_sha ||
    !body.candidate_sha
  ) {
    return c.json({ error: "invalid resolution identity" }, 422);
  }

  const execution = await new D1ExecutionRepository(c.env.DB).resolveMatching({
    repository: body.repository,
    pullRequestNumber: body.pull_request_number,
    baselineSha: body.baseline_sha,
    candidateSha: body.candidate_sha,
    now: new Date().toISOString(),
  });

  if (!execution) {
    c.header("Retry-After", "3");
    return c.json({ error: "matching RunDiff execution is not ready" }, 409);
  }

  return c.json({
    execution_id: execution.id,
    attempt_number: execution.attemptNumber,
  });
});

app.post("/api/execution-bridges/github-actions/claim", async (c) => {
  if (
    !(await tokenAuthorized(
      c.req.header("authorization"),
      c.env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN,
    ))
  ) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const body = await c.req.json<ClaimBody>();
  if (
    !body.repository ||
    !Number.isInteger(body.pull_request_number) ||
    !body.baseline_sha ||
    !body.candidate_sha
  ) {
    return c.json({ error: "invalid claim identity" }, 422);
  }

  const execution = await new D1ExecutionRepository(c.env.DB).claimMatching({
    repository: body.repository,
    pullRequestNumber: body.pull_request_number,
    baselineSha: body.baseline_sha,
    candidateSha: body.candidate_sha,
    now: new Date().toISOString(),
  });

  if (!execution) {
    c.header("Retry-After", "3");
    return c.json({ error: "matching RunDiff execution is not ready" }, 409);
  }

  return c.json({ request: execution.request });
});


app.post(
  "/api/executions/:executionId/attempts/:attemptNumber/claim",
  async (c) => {
    if (
      !(await tokenAuthorized(
        c.req.header("authorization"),
        c.env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN,
      ))
    ) {
      return c.json({ error: "unauthorized" }, 401);
    }

    const attemptNumber = parseAttemptNumber(c.req.param("attemptNumber"));
    if (!attemptNumber) return c.json({ error: "invalid attempt number" }, 422);

    const leaseSeconds = executorLeaseSeconds(c.env);
    const execution = await new D1ExecutionRepository(c.env.DB).claimExact({
      executionId: c.req.param("executionId"),
      attemptNumber,
      leaseSeconds,
      now: new Date().toISOString(),
    });

    if (!execution || !execution.leaseExpiresAt) {
      return c.json({ error: "execution attempt is not claimable" }, 409);
    }

    let repositoryCapability: string | undefined;
    const repository = execution.request.context.repository;
    if (execution.installationId && repository) {
      const repositoryName = repository.split("/", 2)[1];
      if (!repositoryName) {
        return c.json({ error: "invalid executor repository identity" }, 500);
      }
      const github = await GitHubClient.installation(
        c.env,
        execution.installationId,
        undefined,
        repositoryName,
      );
      repositoryCapability = github.accessToken();
    }

    return c.json({
      request: execution.request,
      lease_expires_at: execution.leaseExpiresAt,
      ...(repositoryCapability
        ? { repository_capability: repositoryCapability }
        : {}),
    });
  },
);

app.post(
  "/api/executions/:executionId/attempts/:attemptNumber/heartbeat",
  async (c) => {
    if (
      !(await tokenAuthorized(
        c.req.header("authorization"),
        c.env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN,
      ))
    ) {
      return c.json({ error: "unauthorized" }, 401);
    }

    const attemptNumber = parseAttemptNumber(c.req.param("attemptNumber"));
    if (!attemptNumber) return c.json({ error: "invalid attempt number" }, 422);

    const heartbeat = await new D1ExecutionRepository(c.env.DB).heartbeat({
      executionId: c.req.param("executionId"),
      attemptNumber,
      leaseSeconds: executorLeaseSeconds(c.env),
      now: new Date().toISOString(),
    });

    if (heartbeat.state === "live") {
      return c.json({
        status: "live",
        lease_expires_at: heartbeat.leaseExpiresAt,
      });
    }

    const payload = {
      status: heartbeat.state,
      cancellation_reason: heartbeat.cancellationReason,
    };
    return heartbeat.state === "cancelled" || heartbeat.state === "superseded"
      ? c.json(payload)
      : c.json(payload, 409);
  },
);

app.post(
  "/api/executions/:executionId/attempts/:attemptNumber/cancel",
  async (c) => {
    if (
      !(await tokenAuthorized(
        c.req.header("authorization"),
        c.env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN,
      ))
    ) {
      return c.json({ error: "unauthorized" }, 401);
    }

    const attemptNumber = parseAttemptNumber(c.req.param("attemptNumber"));
    if (!attemptNumber) return c.json({ error: "invalid attempt number" }, 422);

    let body: { reason?: string };
    try {
      body = await c.req.json<{ reason?: string }>();
    } catch {
      body = {};
    }
    const reason = body.reason?.trim();
    if (!reason) return c.json({ error: "cancellation reason is required" }, 422);

    const state = await new D1ExecutionRepository(c.env.DB).cancel({
      executionId: c.req.param("executionId"),
      attemptNumber,
      reason,
      now: new Date().toISOString(),
    });

    if (state === "not_live") {
      return c.json({ error: "execution attempt is no longer cancellable" }, 409);
    }

    return c.json({ status: state }, 202);
  },
);

app.post(
  "/api/executions/:executionId/attempts/:attemptNumber/result",
  async (c) => {
    if (
      !(await tokenAuthorized(
        c.req.header("authorization"),
        c.env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN,
      ))
    ) {
      return c.json({ error: "unauthorized" }, 401);
    }

    let result;
    try {
      result = validateExecutorResult(await c.req.json());
    } catch (error) {
      return c.json(
        {
          error:
            error instanceof Error ? error.message : "invalid executor result",
        },
        422,
      );
    }

    const executionId = c.req.param("executionId");
    const attemptNumber = parseAttemptNumber(c.req.param("attemptNumber"));
    if (!attemptNumber) return c.json({ error: "invalid attempt number" }, 422);

    const digest = await canonicalDigest(result);
    const executions = new D1ExecutionRepository(c.env.DB);
    const state = await executions.recordResult({
      executionId,
      attemptNumber,
      result,
      digest,
      now: new Date().toISOString(),
    });

    if (state === "conflict") {
      return c.json({ error: "result conflicts with recorded result" }, 409);
    }

    if (state === "not_live") {
      return c.json({ error: "execution attempt is no longer live" }, 409);
    }

    const execution = await executions.get(executionId);
    if (!execution) return c.json({ error: "execution not found" }, 404);

    const review = await new D1ReviewRepository(c.env.DB).get(
      execution.reviewId,
    );
    if (!review) return c.json({ error: "review not found" }, 404);

    if (
      execution.status !== "completed" &&
      execution.status !== "infra_failure"
    ) {
      const instance = await c.env.REVIEW_WORKFLOW.get(
        review.workflowInstanceId,
      );
      await instance.sendEvent({
        type: "executor-result",
        payload: {
          executionId,
          attemptNumber,
          resultJson: JSON.stringify(result),
        },
      });
    }

    return c.json(
      { status: state === "duplicate" ? "duplicate" : "accepted" },
      202,
    );
  },
);

export default app;

function parseAttemptNumber(value: string): number | null {
  if (!/^[1-9][0-9]*$/.test(value)) return null;
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : null;
}

function executorLeaseSeconds(env: Env): number {
  const configured = Number(env.RUNDIFF_EXECUTOR_LEASE_SECONDS ?? 90);
  return Number.isSafeInteger(configured) && configured > 5 ? configured : 90;
}

async function tokenAuthorized(
  authorization: string | undefined,
  token: string | undefined,
): Promise<boolean> {
  if (!token || !authorization) return false;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`Bearer ${token}`),
  );
  return crypto.subtle.verify(
    "HMAC",
    key,
    signature,
    encoder.encode(authorization),
  );
}

async function canonicalDigest(value: unknown): Promise<string> {
  const canonical = JSON.stringify(canonicalize(value));
  const bytes = new TextEncoder().encode(canonical);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, nested]) => [key, canonicalize(nested)]),
    );
  }

  return value;
}
