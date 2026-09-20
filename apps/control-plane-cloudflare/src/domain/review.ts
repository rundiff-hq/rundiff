export type ReviewStatus =
  | "starting"
  | "waiting_for_executor"
  | "completed"
  | "infra_failure";

export type ReviewDecision = "ALLOW" | "REVIEW" | "BLOCK" | "INFRA_FAILURE";

export interface BehavioralReview {
  id: string;
  projectId: string;
  scenarioId: string;
  baselineSha: string;
  candidateSha: string;
  status: ReviewStatus;
  decision: ReviewDecision | null;
  workflowInstanceId: string;
  result: unknown | null;
  createdAt: string;
  updatedAt: string;
}

export interface CreateReviewInput {
  id: string;
  projectId: string;
  scenarioId: string;
  baselineSha: string;
  candidateSha: string;
  workflowInstanceId: string;
  now: string;
}

export interface ReviewRepository {
  create(input: CreateReviewInput): Promise<BehavioralReview>;
  get(id: string): Promise<BehavioralReview | null>;
  markWaiting(id: string, now: string): Promise<void>;
  finalize(
    id: string,
    decision: ReviewDecision,
    result: unknown,
    now: string,
  ): Promise<void>;
}
