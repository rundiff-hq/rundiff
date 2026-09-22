export type PullRequestIdentity = {
  deliveryId: string;
  repository: string;
  repositoryId: number;
  pullRequestNumber: number;
  installationId: number;
  baselineSha: string;
  candidateSha: string;
  baselineRef: string;
  candidateRef: string;
  updatedAt: string;
};
export function parsePullRequest(
  value: unknown,
  deliveryId: string,
): PullRequestIdentity | null {
  const p = value as Record<string, any>;
  if (!p || !["opened", "synchronize", "reopened"].includes(p.action))
    return null;
  const pr = p.pull_request;
  if (
    !pr ||
    pr.state !== "open" ||
    !/^[\w.-]+\/[\w.-]+$/.test(p.repository?.full_name ?? "") ||
    !Number.isSafeInteger(p.repository?.id) ||
    !Number.isSafeInteger(p.installation?.id) ||
    !Number.isSafeInteger(pr.number) ||
    pr.number <= 0 ||
    !/^[a-f0-9]{40}$/.test(pr.base?.sha ?? "") ||
    !/^[a-f0-9]{40}$/.test(pr.head?.sha ?? "") ||
    pr.base?.repo?.full_name !== p.repository.full_name ||
    pr.head?.repo?.full_name !== p.repository.full_name ||
    typeof pr.base?.ref !== "string" ||
    typeof pr.head?.ref !== "string" ||
    !Number.isFinite(Date.parse(pr.updated_at))
  ) {
    throw new Error(
      "invalid or unsupported pull request identity (VS1 requires same-repository PRs)",
    );
  }
  return {
    deliveryId,
    repository: p.repository.full_name,
    repositoryId: p.repository.id,
    pullRequestNumber: pr.number,
    installationId: p.installation.id,
    baselineSha: pr.base.sha,
    candidateSha: pr.head.sha,
    baselineRef: pr.base.ref,
    candidateRef: pr.head.ref,
    updatedAt: pr.updated_at,
  };
}
export async function verifyWebhook(
  raw: string,
  signature: string | undefined,
  secret: string,
): Promise<boolean> {
  if (!/^sha256=[a-f0-9]{64}$/.test(signature ?? "")) return false;
  const bytes = Uint8Array.from(signature!.slice(7).match(/../g)!, (x) =>
    parseInt(x, 16),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "HMAC",
    key,
    bytes,
    new TextEncoder().encode(raw),
  );
}
