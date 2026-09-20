import { GitHubClient, type GitHubCredentials } from "./client";
import { D1GitHubRepository } from "../d1/github-repository";

type Publication = {
  id: string;
  review_id: string;
  repository: string;
  pull_request_number: number;
  candidate_sha: string;
  installation_id: number | null;
  decision: string;
  check_id: number | null;
  comment_id: number | null;
  status: string;
};
export async function publishReview(
  db: D1Database,
  credentials: GitHubCredentials,
  executionId: string,
) {
  const row = await db
    .prepare(
      `SELECT e.id,e.review_id,e.repository,e.pull_request_number,e.candidate_sha,e.installation_id,r.decision,p.check_id,p.comment_id,p.status FROM executions e JOIN behavioral_reviews r ON r.id=e.review_id JOIN github_publications p ON p.execution_id=e.id WHERE e.id=?`,
    )
    .bind(executionId)
    .first<Publication>();
  if (!row?.installation_id || row.status === "published") return;
  const repo = new D1GitHubRepository(db);
  const github = await GitHubClient.installation(
    credentials,
    row.installation_id,
  );
  const current = async () =>
    (await repo.current(executionId)) &&
    (await github.current(
      row.repository,
      row.pull_request_number,
      row.candidate_sha,
    ));
  if (!(await current())) return;
  const prefix = `/repos/${row.repository}`;
  const summary = `**${row.decision}**\n\nCandidate: \`${row.candidate_sha}\`\nExecution: \`${executionId}\`${row.decision === "INFRA_FAILURE" ? "\n\nExecution infrastructure failure; rerun after recovery." : ""}`;
  let checkId = row.check_id;
  if (!checkId) {
    // Recover a successful POST whose response was lost before D1 persistence.
    const existing = await github.request<{
      check_runs: Array<{ id: number; external_id: string }>;
    }>(
      `${prefix}/commits/${row.candidate_sha}/check-runs?check_name=RunDiff%20%2F%20Behavioral%20Review&per_page=100`,
    );
    checkId =
      existing.check_runs.find((c) => c.external_id === executionId)?.id ??
      null;
  }
  if (!(await current())) return;
  const checkBody = {
    name: "RunDiff / Behavioral Review",
    status: "completed",
    conclusion:
      row.decision === "ALLOW"
        ? "success"
        : row.decision === "REVIEW"
          ? "action_required"
          : "failure",
    output: { title: `RunDiff: ${row.decision}`, summary },
  };
  const check = await github.request<{ id: number }>(
    checkId ? `${prefix}/check-runs/${checkId}` : `${prefix}/check-runs`,
    checkId ? "PATCH" : "POST",
    checkId
      ? checkBody
      : { ...checkBody, head_sha: row.candidate_sha, external_id: executionId },
  );
  await db
    .prepare("UPDATE github_publications SET check_id=? WHERE execution_id=?")
    .bind(check.id, executionId)
    .run();
  if (!(await current())) return;
  const pr = await db
    .prepare(
      "SELECT comment_id FROM github_pull_requests WHERE repository=? AND pull_request_number=? AND review_id=?",
    )
    .bind(row.repository, row.pull_request_number, row.review_id)
    .first<{ comment_id: number | null }>();
  if (!pr) return;
  let commentId = pr.comment_id;
  const marker = "<!-- rundiff:behavioral-diff:v1 -->";
  if (!commentId) {
    for (let page = 1; ; page++) {
      const comments = await github.request<
        Array<{
          id: number;
          body: string;
          performed_via_github_app?: { id: number };
        }>
      >(
        `${prefix}/issues/${row.pull_request_number}/comments?per_page=100&page=${page}`,
      );
      commentId =
        comments.find(
          (c) =>
            String(c.performed_via_github_app?.id) ===
              credentials.RUNDIFF_GITHUB_APP_ID && c.body.startsWith(marker),
        )?.id ?? null;
      if (commentId || comments.length < 100) break;
    }
  }
  if (!(await current())) return;
  const comment = await github.request<{ id: number }>(
    commentId
      ? `${prefix}/issues/comments/${commentId}`
      : `${prefix}/issues/${row.pull_request_number}/comments`,
    commentId ? "PATCH" : "POST",
    { body: `${marker}\n## RunDiff Behavioral Review\n\n${summary}` },
  );
  await db.batch([
    db
      .prepare(
        "UPDATE github_pull_requests SET comment_id=? WHERE repository=? AND pull_request_number=? AND review_id=?",
      )
      .bind(comment.id, row.repository, row.pull_request_number, row.review_id),
    db
      .prepare(
        "UPDATE github_publications SET status='published',comment_id=? WHERE execution_id=?",
      )
      .bind(comment.id, executionId),
  ]);
}
