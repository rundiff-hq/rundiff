import type { PullRequestIdentity } from "../../domain/github";
import type { ExecutorRequestV1 } from "../../domain/executor";

export class D1GitHubRepository {
  constructor(private readonly db: D1Database) {}
  async accept(
    identity: PullRequestIdentity,
    digest: string,
    scenarioId: string,
    timeoutSeconds: number,
  ) {
    const old = await this.db
      .prepare("SELECT digest, review_id FROM github_deliveries WHERE id = ?")
      .bind(identity.deliveryId)
      .first<{ digest: string; review_id: string }>();
    if (old) {
      if (old.digest !== digest) throw new Error("delivery content conflict");
      const execution = await this.db
        .prepare("SELECT id FROM executions WHERE review_id = ?")
        .bind(old.review_id)
        .first<{ id: string }>();
      return {
        reviewId: old.review_id,
        executionId: execution!.id,
        duplicate: true,
      };
    }
    const reviewId = crypto.randomUUID(),
      executionId = crypto.randomUUID(),
      now = new Date().toISOString();
    const request: ExecutorRequestV1 = {
      schema_version: "1",
      execution_id: executionId,
      scenario_id: scenarioId,
      baseline_sha: identity.baselineSha,
      candidate_sha: identity.candidateSha,
      attempt_number: 1,
      context: {
        repository: identity.repository,
        pull_request_number: identity.pullRequestNumber,
        baseline_ref: identity.baselineRef,
        candidate_ref: identity.candidateRef,
        candidate_repository: identity.repository,
      },
    };
    // A D1 batch is one transaction: dedupe, candidate authority and superseding commit together.
    await this.db.batch([
      this.db
        .prepare("INSERT INTO github_deliveries VALUES (?, ?, ?, ?)")
        .bind(identity.deliveryId, digest, reviewId, now),
      this.db
        .prepare(
          `INSERT INTO behavioral_reviews (id,project_id,scenario_id,baseline_sha,candidate_sha,status,workflow_instance_id,created_at,updated_at) VALUES (?,?,?,?,?,'starting',?,?,?)`,
        )
        .bind(
          reviewId,
          identity.repository,
          scenarioId,
          identity.baselineSha,
          identity.candidateSha,
          reviewId,
          now,
          now,
        ),
      this.db
        .prepare(
          `INSERT INTO executions (id,review_id,repository,pull_request_number,scenario_id,baseline_sha,candidate_sha,attempt_number,status,request_json,created_at,updated_at,installation_id,github_delivery_id,expires_at) VALUES (?,?,?,?,?,?,?,1,'available',?,?,?,?,?,?)`,
        )
        .bind(
          executionId,
          reviewId,
          identity.repository,
          identity.pullRequestNumber,
          scenarioId,
          identity.baselineSha,
          identity.candidateSha,
          JSON.stringify(request),
          now,
          now,
          identity.installationId,
          identity.deliveryId,
          new Date(Date.now() + timeoutSeconds * 1000).toISOString(),
        ),
      this.db
        .prepare(
          `INSERT INTO github_pull_requests (repository,pull_request_number,installation_id,review_id,candidate_sha,updated_at) VALUES (?,?,?,?,?,?) ON CONFLICT(repository,pull_request_number) DO UPDATE SET installation_id=excluded.installation_id,review_id=excluded.review_id,candidate_sha=excluded.candidate_sha,updated_at=excluded.updated_at WHERE excluded.updated_at >= github_pull_requests.updated_at`,
        )
        .bind(
          identity.repository,
          identity.pullRequestNumber,
          identity.installationId,
          reviewId,
          identity.candidateSha,
          identity.updatedAt,
        ),
      this.db
        .prepare(
          `UPDATE executions SET status='superseded',cancelled_at=?,cancellation_reason='superseded_by_new_pull_request_revision',lease_expires_at=NULL,updated_at=? WHERE repository=? AND pull_request_number=? AND review_id != (SELECT review_id FROM github_pull_requests WHERE repository=? AND pull_request_number=?) AND status IN ('available','claimed','result_received')`,
        )
        .bind(
          now,
          now,
          identity.repository,
          identity.pullRequestNumber,
          identity.repository,
          identity.pullRequestNumber,
        ),
      this.db
        .prepare(
          `UPDATE behavioral_reviews SET status='superseded',updated_at=? WHERE id IN (SELECT review_id FROM executions WHERE repository=? AND pull_request_number=? AND status='superseded')`,
        )
        .bind(now, identity.repository, identity.pullRequestNumber),
      this.db
        .prepare(`INSERT INTO github_publications(execution_id) VALUES (?)`)
        .bind(executionId),
    ]);
    return { reviewId, executionId, duplicate: false };
  }
  async current(executionId: string): Promise<boolean> {
    return !!(await this.db
      .prepare(
        `SELECT e.id FROM executions e JOIN github_pull_requests p ON e.review_id=p.review_id AND e.installation_id=p.installation_id WHERE e.id=?`,
      )
      .bind(executionId)
      .first());
  }
}
