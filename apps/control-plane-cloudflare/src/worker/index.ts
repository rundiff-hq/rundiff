import { Hono } from "hono";

import { D1ReviewRepository } from "../adapters/d1/review-repository";
import type { Env } from "./env";
export { BehavioralReviewWorkflow } from "./workflows/behavioral-review";

type CreateSpikeReviewBody = {
  project_id: string;
  scenario_id: string;
  baseline_sha: string;
  candidate_sha: string;
};

type SpikeResultBody = {
  decision: "ALLOW" | "REVIEW" | "BLOCK";
  result?: unknown;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/api/health", (c) => c.json({ ok: true, service: "rundiff-control-plane" }));

app.get("/api/ready", async (c) => {
  await c.env.DB.prepare("SELECT 1").first();
  return c.json({ ok: true, d1: "ready" });
});

app.post("/api/spike/reviews", async (c) => {
  const body = await c.req.json<CreateSpikeReviewBody>();

  if (
    !body.project_id ||
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

  const review = await reviews.create({
    id,
    projectId: body.project_id,
    scenarioId: body.scenario_id,
    baselineSha: body.baseline_sha,
    candidateSha: body.candidate_sha,
    workflowInstanceId,
    now,
  });

  await c.env.REVIEW_WORKFLOW.create({
    id: workflowInstanceId,
    params: { reviewId: id },
  });

  return c.json({ review }, 201);
});

app.get("/api/reviews/:id", async (c) => {
  const review = await new D1ReviewRepository(c.env.DB).get(c.req.param("id"));
  return review
    ? c.json({ review })
    : c.json({ error: "review not found" }, 404);
});

app.post("/api/spike/reviews/:id/result", async (c) => {
  if (c.env.RUNDIFF_SPIKE_TOKEN) {
    const expected = `Bearer ${c.env.RUNDIFF_SPIKE_TOKEN}`;
    if (c.req.header("authorization") !== expected) {
      return c.json({ error: "unauthorized" }, 401);
    }
  }

  const reviews = new D1ReviewRepository(c.env.DB);
  const review = await reviews.get(c.req.param("id"));
  if (!review) return c.json({ error: "review not found" }, 404);

  const body = await c.req.json<SpikeResultBody>();
  if (!["ALLOW", "REVIEW", "BLOCK"].includes(body.decision)) {
    return c.json({ error: "invalid decision" }, 422);
  }

  const instance = await c.env.REVIEW_WORKFLOW.get(review.workflowInstanceId);
  await instance.sendEvent({
    type: "executor-result",
    payload: {
      decision: body.decision,
      result: body.result ?? {},
    },
  });

  return c.json({ accepted: true }, 202);
});

export default app;
