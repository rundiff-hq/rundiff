import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import { publishReview } from "../../adapters/github/publication";
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
    try {
      await step.do("mark waiting for executor", async () => {
        await new D1ReviewRepository(this.env.DB).markWaiting(
          reviewId,
          new Date().toISOString(),
        );
      });
      const resultEvent = await step.waitForEvent<ExecutorResultEvent>(
        "wait for executor result",
        {
          type: "executor-result",
          timeout: this.env.RUNDIFF_EXECUTOR_TIMEOUT_SECONDS
            ? `${Number(this.env.RUNDIFF_EXECUTOR_TIMEOUT_SECONDS)} seconds`
            : "30 minutes",
        },
      );
      const payload = resultEvent.payload;
      if (
        payload.executionId !== executionId ||
        payload.attemptNumber !== attemptNumber
      )
        throw new Error("executor result identity mismatch");
      const result = validateExecutorResult(JSON.parse(payload.resultJson));
      await step.do("finalize review", async () => {
        const executions = new D1ExecutionRepository(this.env.DB);
        const stored = await executions.get(executionId);
        // Events are wakeups; only the result accepted by the durable bridge is authoritative.
        if (
          !stored?.result ||
          JSON.stringify(stored.result) !== JSON.stringify(result)
        )
          throw new Error("executor result is not durably accepted");
        await executions.finalize(
          executionId,
          attemptNumber,
          decisionFromExecutorResult(stored.result),
          stored.result,
          new Date().toISOString(),
        );
      });
    } catch (error) {
      await step.do("mark executor timeout or lifecycle failure", async () => {
        await new D1ExecutionRepository(this.env.DB).finalize(
          executionId,
          attemptNumber,
          "INFRA_FAILURE",
          {
            code: "EXECUTOR_RESULT_TIMEOUT_OR_LIFECYCLE_FAILURE",
            message:
              error instanceof Error
                ? error.message
                : "executor lifecycle failure",
          },
          new Date().toISOString(),
        );
      });
    }
    // Publication failures retry independently; they cannot rewrite a completed decision.
    await step.do("publish GitHub review", async () =>
      publishReview(this.env.DB, this.env, executionId),
    );
    const review = await step.do("read durable outcome", async () => {
      const r = await new D1ReviewRepository(this.env.DB).get(reviewId);
      return { decision: r?.decision ?? null, status: r?.status ?? null };
    });
    return {
      reviewId,
      executionId,
      attemptNumber,
      decision: review?.decision,
      status: review?.status,
    };
  }
}
