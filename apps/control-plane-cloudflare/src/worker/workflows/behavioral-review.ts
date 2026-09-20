import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";

import { D1ExecutionRepository } from "../../adapters/d1/execution-repository";
import { D1ReviewRepository } from "../../adapters/d1/review-repository";
import {
  decisionFromExecutorResult,
  validateExecutorResult,
} from "../../domain/executor";
import type { Env } from "../env";

export type BehavioralReviewWorkflowParams = {
  reviewId: string;
  executionId: string;
  attemptNumber: number;
};

type ExecutorResultEvent = {
  executionId: string;
  attemptNumber: number;
  resultJson: string;
};

export class BehavioralReviewWorkflow extends WorkflowEntrypoint<
  Env,
  BehavioralReviewWorkflowParams
> {
  async run(
    event: WorkflowEvent<BehavioralReviewWorkflowParams>,
    step: WorkflowStep,
  ) {
    const { reviewId, executionId, attemptNumber } = event.payload;

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

      if (
        payload.executionId !== executionId ||
        payload.attemptNumber !== attemptNumber
      ) {
        throw new Error("executor result identity mismatch");
      }

      const result = validateWorkflowExecutorResult(payload.resultJson);
      const decision = decisionFromExecutorResult(result);

      await step.do("finalize review", async () => {
        const now = new Date().toISOString();
        const reviews = new D1ReviewRepository(this.env.DB);
        const executions = new D1ExecutionRepository(this.env.DB);

        await reviews.finalize(reviewId, decision, result, now);
        await executions.markTerminal(
          executionId,
          attemptNumber,
          decision === "INFRA_FAILURE" ? "infra_failure" : "completed",
          now,
        );
      });

      return { reviewId, executionId, attemptNumber, decision };
    } catch (error) {
      await step.do("mark executor timeout or lifecycle failure", async () => {
        const now = new Date().toISOString();
        const reviews = new D1ReviewRepository(this.env.DB);
        const executions = new D1ExecutionRepository(this.env.DB);

        const failure = {
          code: "EXECUTOR_RESULT_TIMEOUT_OR_LIFECYCLE_FAILURE",
          message:
            error instanceof Error ? error.message : "executor lifecycle failure",
        };

        await reviews.finalize(reviewId, "INFRA_FAILURE", failure, now);
        await executions.markTerminal(
          executionId,
          attemptNumber,
          "infra_failure",
          now,
        );
      });

      return {
        reviewId,
        executionId,
        attemptNumber,
        decision: "INFRA_FAILURE" as const,
      };
    }
  }
}

function validateWorkflowExecutorResult(resultJson: string) {
  let parsed: unknown;

  try {
    parsed = JSON.parse(resultJson);
  } catch {
    throw new Error("executor result event contains invalid JSON");
  }

  return validateExecutorResult(parsed);
}
