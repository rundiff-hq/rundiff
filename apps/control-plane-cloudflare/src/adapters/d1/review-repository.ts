import type {
  BehavioralReview,
  CreateReviewInput,
  ReviewDecision,
  ReviewRepository,
} from "../../domain/review";

type ReviewRow = {
  id: string;
  project_id: string;
  scenario_id: string;
  baseline_sha: string;
  candidate_sha: string;
  status: BehavioralReview["status"];
  decision: ReviewDecision | null;
  workflow_instance_id: string;
  result_json: string | null;
  created_at: string;
  updated_at: string;
};

export class D1ReviewRepository implements ReviewRepository {
  constructor(private readonly db: D1Database) {}

  async create(input: CreateReviewInput): Promise<BehavioralReview> {
    await this.db
      .prepare(
        `INSERT INTO behavioral_reviews
          (id, project_id, scenario_id, baseline_sha, candidate_sha, status,
           decision, workflow_instance_id, result_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'starting', NULL, ?, NULL, ?, ?)`,
      )
      .bind(
        input.id,
        input.projectId,
        input.scenarioId,
        input.baselineSha,
        input.candidateSha,
        input.workflowInstanceId,
        input.now,
        input.now,
      )
      .run();

    return (await this.get(input.id))!;
  }

  async get(id: string): Promise<BehavioralReview | null> {
    const row = await this.db
      .prepare("SELECT * FROM behavioral_reviews WHERE id = ?")
      .bind(id)
      .first<ReviewRow>();

    return row ? mapRow(row) : null;
  }

  async markWaiting(id: string, now: string): Promise<void> {
    await this.db
      .prepare(
        "UPDATE behavioral_reviews SET status = 'waiting_for_executor', updated_at = ? WHERE id = ?",
      )
      .bind(now, id)
      .run();
  }

  async finalize(
    id: string,
    decision: ReviewDecision,
    result: unknown,
    now: string,
  ): Promise<void> {
    await this.db
      .prepare(
        `UPDATE behavioral_reviews
         SET status = ?, decision = ?, result_json = ?, updated_at = ?
         WHERE id = ?`,
      )
      .bind(
        decision === "INFRA_FAILURE" ? "infra_failure" : "completed",
        decision,
        JSON.stringify(result),
        now,
        id,
      )
      .run();
  }
}

function mapRow(row: ReviewRow): BehavioralReview {
  return {
    id: row.id,
    projectId: row.project_id,
    scenarioId: row.scenario_id,
    baselineSha: row.baseline_sha,
    candidateSha: row.candidate_sha,
    status: row.status,
    decision: row.decision,
    workflowInstanceId: row.workflow_instance_id,
    result: row.result_json ? JSON.parse(row.result_json) : null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}
