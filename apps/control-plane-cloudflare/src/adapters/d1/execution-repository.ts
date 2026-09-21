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
  claimed_at: string | null;
  heartbeat_at: string | null;
  lease_expires_at: string | null;
  cancelled_at: string | null;
  cancellation_reason: string | null;
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
  claimedAt: string | null;
  heartbeatAt: string | null;
  leaseExpiresAt: string | null;
  cancelledAt: string | null;
  cancellationReason: string | null;
};

export type HeartbeatState =
  | { state: "live"; leaseExpiresAt: string }
  | {
      state: "cancelled" | "superseded" | "expired" | "not_live";
      cancellationReason: string | null;
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

  async resolveMatching(input: {
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
           AND (expires_at IS NULL OR expires_at > ?)
           AND (installation_id IS NULL OR review_id IN (SELECT review_id FROM github_pull_requests))
         ORDER BY created_at DESC
         LIMIT 1`,
      )
      .bind(
        input.repository,
        input.pullRequestNumber,
        input.baselineSha,
        input.candidateSha,
        input.now,
      )
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
    const row = await this.resolveMatching(input);
    if (!row) return null;

    const update = await this.db
      .prepare(
        `UPDATE executions
         SET status = 'claimed', updated_at = ?
         WHERE id = ? AND status = 'available'
           AND (expires_at IS NULL OR expires_at > ?)
           AND (installation_id IS NULL OR review_id IN (SELECT review_id FROM github_pull_requests))`,
      )
      .bind(input.now, row.id, input.now)
      .run();

    if ((update.meta.changes ?? 0) !== 1) return null;
    return this.get(row.id);
  }

  async claimExact(input: {
    executionId: string;
    attemptNumber: number;
    leaseSeconds: number;
    now: string;
  }): Promise<ExecutionRecord | null> {
    const leaseExpiresAt = addSeconds(input.now, input.leaseSeconds);
    const update = await this.db
      .prepare(
        `UPDATE executions
         SET status = 'claimed',
             claimed_at = COALESCE(claimed_at, ?),
             heartbeat_at = ?,
             lease_expires_at = ?,
             updated_at = ?
         WHERE id = ?
           AND attempt_number = ?
           AND status = 'available'
           AND (expires_at IS NULL OR expires_at > ?)
           AND (installation_id IS NULL OR review_id IN (SELECT review_id FROM github_pull_requests))`,
      )
      .bind(
        input.now,
        input.now,
        leaseExpiresAt,
        input.now,
        input.executionId,
        input.attemptNumber,
        input.now,
      )
      .run();

    if ((update.meta.changes ?? 0) !== 1) return null;
    return this.get(input.executionId);
  }

  async heartbeat(input: {
    executionId: string;
    attemptNumber: number;
    leaseSeconds: number;
    now: string;
  }): Promise<HeartbeatState> {
    const leaseExpiresAt = addSeconds(input.now, input.leaseSeconds);
    const update = await this.db
      .prepare(
        `UPDATE executions
         SET heartbeat_at = ?, lease_expires_at = ?, updated_at = ?
         WHERE id = ?
           AND attempt_number = ?
           AND status = 'claimed'
           AND lease_expires_at IS NOT NULL
           AND lease_expires_at > ?
           AND (expires_at IS NULL OR expires_at > ?)
           AND (installation_id IS NULL OR review_id IN (SELECT review_id FROM github_pull_requests))`,
      )
      .bind(
        input.now,
        leaseExpiresAt,
        input.now,
        input.executionId,
        input.attemptNumber,
        input.now,
        input.now,
      )
      .run();

    if ((update.meta.changes ?? 0) === 1) {
      return { state: "live", leaseExpiresAt };
    }

    const current = await this.get(input.executionId);
    if (!current || current.attemptNumber !== input.attemptNumber) {
      return { state: "not_live", cancellationReason: null };
    }

    if (current.status === "cancelled" || current.status === "superseded") {
      return {
        state: current.status,
        cancellationReason: current.cancellationReason,
      };
    }

    if (
      current.status === "claimed" &&
      current.leaseExpiresAt &&
      current.leaseExpiresAt <= input.now
    ) {
      return {
        state: "expired",
        cancellationReason: "execution_lease_expired",
      };
    }

    return {
      state: "not_live",
      cancellationReason: current.cancellationReason,
    };
  }

  async cancel(input: {
    executionId: string;
    attemptNumber: number;
    reason: string;
    now: string;
  }): Promise<"cancelled" | "already_cancelled" | "not_live"> {
    const current = await this.get(input.executionId);
    if (!current || current.attemptNumber !== input.attemptNumber) {
      return "not_live";
    }
    if (current.status === "cancelled") return "already_cancelled";
    if (!["available", "claimed"].includes(current.status)) return "not_live";

    const update = await this.db
      .prepare(
        `UPDATE executions
         SET status = 'cancelled',
             cancelled_at = ?,
             cancellation_reason = ?,
             lease_expires_at = NULL,
             updated_at = ?
         WHERE id = ?
           AND attempt_number = ?
           AND status IN ('available', 'claimed')`,
      )
      .bind(
        input.now,
        input.reason,
        input.now,
        input.executionId,
        input.attemptNumber,
      )
      .run();

    if ((update.meta.changes ?? 0) !== 1) return "not_live";

    await this.db
      .prepare(
        `UPDATE behavioral_reviews
         SET status = 'cancelled', decision = NULL, updated_at = ?
         WHERE id = (SELECT review_id FROM executions WHERE id = ?)
           AND status IN ('starting', 'waiting_for_executor')`,
      )
      .bind(input.now, input.executionId)
      .run();

    return "cancelled";
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
             lease_expires_at = NULL,
             updated_at = ?
         WHERE id = ?
           AND attempt_number = ?
           AND status = 'claimed'
           AND result_digest IS NULL
           AND (lease_expires_at IS NULL OR lease_expires_at > ?)
           AND (expires_at IS NULL OR expires_at > ?)
           AND (installation_id IS NULL OR review_id IN (SELECT review_id FROM github_pull_requests))`,
      )
      .bind(
        JSON.stringify(input.result),
        input.digest,
        input.now,
        input.executionId,
        input.attemptNumber,
        input.now,
        input.now,
      )
      .run();

    if ((update.meta.changes ?? 0) === 1) return "accepted";
    const raced = await this.get(input.executionId);
    return raced?.resultDigest
      ? raced.resultDigest === input.digest
        ? "duplicate"
        : "conflict"
      : "not_live";
  }

  async finalize(
    executionId: string,
    attemptNumber: number,
    decision: string,
    result: unknown,
    now: string,
  ): Promise<void> {
    const status = decision === "INFRA_FAILURE" ? "infra_failure" : "completed";
    await this.db.batch([
      this.db
        .prepare(
          `UPDATE executions SET status=?,lease_expires_at=NULL,updated_at=? WHERE id=? AND attempt_number=?
        AND status IN ('available','claimed','result_received')
        AND (installation_id IS NULL OR review_id IN (SELECT review_id FROM github_pull_requests))`,
        )
        .bind(status, now, executionId, attemptNumber),
      this.db
        .prepare(
          `UPDATE behavioral_reviews SET status=?,decision=?,result_json=?,updated_at=?
        WHERE id=(SELECT review_id FROM executions WHERE id=? AND attempt_number=? AND status=? AND updated_at=?)
        AND status IN ('starting','waiting_for_executor')`,
        )
        .bind(
          status,
          decision,
          JSON.stringify(result),
          now,
          executionId,
          attemptNumber,
          status,
          now,
        ),
    ]);
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
    claimedAt: row.claimed_at ?? null,
    heartbeatAt: row.heartbeat_at ?? null,
    leaseExpiresAt: row.lease_expires_at ?? null,
    cancelledAt: row.cancelled_at ?? null,
    cancellationReason: row.cancellation_reason ?? null,
  };
}

function addSeconds(iso: string, seconds: number): string {
  return new Date(Date.parse(iso) + seconds * 1000).toISOString();
}
