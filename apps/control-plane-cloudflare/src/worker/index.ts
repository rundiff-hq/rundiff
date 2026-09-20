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

app.post("/api/spike/reviews", async (c) => {
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
  const review = await new D1ReviewRepository(c.env.DB).get(c.req.param("id"));
  return review
    ? c.json({ review })
    : c.json({ error: "review not found" }, 404);
});

app.post("/api/execution-bridges/github-actions/claim", async (c) => {
  if (!bridgeAuthorized(c.req.header("authorization"), c.env)) {
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
  "/api/executions/:executionId/attempts/:attemptNumber/result",
  async (c) => {
    if (!bridgeAuthorized(c.req.header("authorization"), c.env)) {
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
    const attemptNumber = Number.parseInt(c.req.param("attemptNumber"), 10);
    if (!Number.isInteger(attemptNumber)) {
      return c.json({ error: "invalid attempt number" }, 422);
    }

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

    if (execution.status !== "completed" && execution.status !== "infra_failure") {
      const instance = await c.env.REVIEW_WORKFLOW.get(
        review.workflowInstanceId,
      );
      await instance.sendEvent({
        type: "executor-result",
        payload: {
          executionId,
          attemptNumber,
          result,
        },
      });
    }

    return c.json({ status: state === "duplicate" ? "duplicate" : "accepted" }, 202);
  },
);

export default app;

function bridgeAuthorized(
  authorization: string | undefined,
  env: Env,
): boolean {
  const token = env.RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN;
  if (!token) return false;
  return authorization === `Bearer ${token}`;
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
