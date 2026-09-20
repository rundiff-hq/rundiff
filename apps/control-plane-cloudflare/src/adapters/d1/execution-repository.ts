import type {
  ExecutorRequestV1,
  ExecutorResultV1,
} from "../../domain/executor";

type ExecutionRow = {
  id: string;
  review_id: string;
  repository: string;
  pull_request_number: number;
  scenario_id: string;
  baseline_sha: string;
  candidate_sha: string;
  attempt_number: number;
  status: string;
  request_json: string;
  result_json: string | null;
  result_digest: string | null;
  created_at: string;
  updated_at: string;
};

export type ExecutionRecord = {
  id: string;
  reviewId: string;
  status: string;
  request: ExecutorRequestV1;
  result: ExecutorResultV1 | null;
  resultDigest: string | null;
  attemptNumber: number;
};

export class D1ExecutionRepository {
  constructor(private readonly db: D1Database) {}

  async create(input: {
    reviewId: string;
    repository: string;
    pullRequestNumber: number;
    scenarioId: string;
    baselineSha: string;
    candidateSha: string;
    baselineRef: string;
    candidateRef: string;
    candidateRepository: string;
    now: string;
  }): Promise<ExecutionRecord> {
    const id = crypto.randomUUID();
    const request: ExecutorRequestV1 = {
      schema_version: "1",
      execution_id: id,
      scenario_id: input.scenarioId,
      baseline_sha: input.baselineSha,
      candidate_sha: input.candidateSha,
      attempt_number: 1,
      context: {
        repository: input.repository,
        pull_request_number: input.pullRequestNumber,
        baseline_ref: input.baselineRef,
        candidate_ref: input.candidateRef,
        candidate_repository: input.candidateRepository,
      },
    };

    await this.db
      .prepare(
        `INSERT INTO executions
          (id, review_id, repository, pull_request_number, scenario_id,
           baseline_sha, candidate_sha, attempt_number, status, request_json,
           result_json, result_digest, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'available', ?, NULL, NULL, ?, ?)`,
      )
      .bind(
        id,
        input.reviewId,
        input.repository,
        input.pullRequestNumber,
        input.scenarioId,
        input.baselineSha,
        input.candidateSha,
        JSON.stringify(request),
        input.now,
        input.now,
      )
      .run();

    return (await this.get(id))!;
  }

  async get(id: string): Promise<ExecutionRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM executions WHERE id = ?")
      .bind(id)
      .first<ExecutionRow>();

    return row ? mapRow(row) : null;
  }

  async claimMatching(input: {
    repository: string;
    pullRequestNumber: number;
    baselineSha: string;
    candidateSha: string;
    now: string;
  }): Promise<ExecutionRecord | null> {
    const row = await this.db
      .prepare(
        `SELECT * FROM executions
         WHERE repository = ?
           AND pull_request_number = ?
           AND baseline_sha = ?
           AND candidate_sha = ?
           AND status = 'available'
         ORDER BY created_at DESC
         LIMIT 1`,
      )
      .bind(
        input.repository,
        input.pullRequestNumber,
        input.baselineSha,
        input.candidateSha,
      )
      .first<ExecutionRow>();

    if (!row) return null;

    const update = await this.db
      .prepare(
        `UPDATE executions
         SET status = 'claimed', updated_at = ?
         WHERE id = ? AND status = 'available'`,
      )
      .bind(input.now, row.id)
      .run();

    if ((update.meta.changes ?? 0) !== 1) return null;
    return this.get(row.id);
  }

  async recordResult(input: {
    executionId: string;
    attemptNumber: number;
    result: ExecutorResultV1;
    digest: string;
    now: string;
  }): Promise<"accepted" | "duplicate" | "conflict" | "not_live"> {
    const current = await this.get(input.executionId);
    if (!current || current.attemptNumber !== input.attemptNumber) {
      return "not_live";
    }

    if (current.resultDigest) {
      return current.resultDigest === input.digest ? "duplicate" : "conflict";
    }

    if (current.status !== "claimed") return "not_live";

    const update = await this.db
      .prepare(
        `UPDATE executions
         SET status = 'result_received',
             result_json = ?,
             result_digest = ?,
             updated_at = ?
         WHERE id = ?
           AND attempt_number = ?
           AND status = 'claimed'
           AND result_digest IS NULL`,
      )
      .bind(
        JSON.stringify(input.result),
        input.digest,
        input.now,
        input.executionId,
        input.attemptNumber,
      )
      .run();

    return (update.meta.changes ?? 0) === 1 ? "accepted" : "not_live";
  }

  async markTerminal(
    executionId: string,
    attemptNumber: number,
    status: "completed" | "infra_failure",
    now: string,
  ): Promise<void> {
    await this.db
      .prepare(
        `UPDATE executions
         SET status = ?, updated_at = ?
         WHERE id = ?
           AND attempt_number = ?
           AND status IN ('available', 'claimed', 'result_received', 'completed', 'infra_failure')`,
      )
      .bind(status, now, executionId, attemptNumber)
      .run();
  }
}

function mapRow(row: ExecutionRow): ExecutionRecord {
  return {
    id: row.id,
    reviewId: row.review_id,
    status: row.status,
    request: JSON.parse(row.request_json) as ExecutorRequestV1,
    result: row.result_json
      ? (JSON.parse(row.result_json) as ExecutorResultV1)
      : null,
    resultDigest: row.result_digest,
    attemptNumber: row.attempt_number,
  };
}
