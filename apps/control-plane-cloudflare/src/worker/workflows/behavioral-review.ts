import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";

import { D1ReviewRepository } from "../../adapters/d1/review-repository";
import type { ReviewDecision } from "../../domain/review";
import type { Env } from "../env";

export type BehavioralReviewWorkflowParams = {
  reviewId: string;
};

type ExecutorResultEvent = {
  decision: Exclude<ReviewDecision, "INFRA_FAILURE">;
  result: unknown;
};

export class BehavioralReviewWorkflow extends WorkflowEntrypoint<
  Env,
  BehavioralReviewWorkflowParams
> {
  async run(
    event: WorkflowEvent<BehavioralReviewWorkflowParams>,
    step: WorkflowStep,
  ) {
    const reviewId = event.payload.reviewId;

    await step.do("mark waiting for executor", async () => {
      const reviews = new D1ReviewRepository(this.env.DB);
      await reviews.markWaiting(reviewId, new Date().toISOString());
    });

    try {
      const resultEvent = await step.waitForEvent<ExecutorResultEvent>(
        "wait for executor result",
        {
          type: "executor-result",
          timeout: "30 minutes",
        },
      );

      const payload =
        "payload" in resultEvent
          ? (resultEvent.payload as ExecutorResultEvent)
          : (resultEvent as unknown as ExecutorResultEvent);

      await step.do("finalize review", async () => {
        const reviews = new D1ReviewRepository(this.env.DB);
        await reviews.finalize(
          reviewId,
          payload.decision,
          payload.result,
          new Date().toISOString(),
        );
      });

      return { reviewId, decision: payload.decision };
    } catch (error) {
      await step.do("mark executor timeout", async () => {
        const reviews = new D1ReviewRepository(this.env.DB);
        await reviews.finalize(
          reviewId,
          "INFRA_FAILURE",
          {
            code: "EXECUTOR_RESULT_TIMEOUT",
            message: error instanceof Error ? error.message : "executor result timeout",
          },
          new Date().toISOString(),
        );
      });

      return { reviewId, decision: "INFRA_FAILURE" as const };
    }
  }
}
