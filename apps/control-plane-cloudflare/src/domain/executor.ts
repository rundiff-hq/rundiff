export type ExecutorRequestV1 = {
  schema_version: "1";
  execution_id: string;
  scenario_id: string;
  baseline_sha: string;
  candidate_sha: string;
  attempt_number: number;
  context: {
    repository?: string;
    pull_request_number?: number;
    baseline_ref?: string;
    candidate_ref?: string;
    candidate_repository?: string;
  };
};

export type ExecutorResultV1 = {
  schema_version: "1";
  status: "succeeded" | "failed";
  payload: unknown | null;
  error_class: string | null;
  error_message: string | null;
};

export function validateExecutorResult(value: unknown): ExecutorResultV1 {
  if (!value || typeof value !== "object") {
    throw new Error("executor result must be an object");
  }

  const result = value as Record<string, unknown>;

  if (result.schema_version !== "1") {
    throw new Error("unsupported executor result schema");
  }

  if (result.status !== "succeeded" && result.status !== "failed") {
    throw new Error("unsupported executor result status");
  }

  return {
    schema_version: "1",
    status: result.status,
    payload: result.payload ?? null,
    error_class:
      typeof result.error_class === "string" ? result.error_class : null,
    error_message:
      typeof result.error_message === "string" ? result.error_message : null,
  };
}

export function decisionFromExecutorResult(
  result: ExecutorResultV1,
): "ALLOW" | "REVIEW" | "BLOCK" | "INFRA_FAILURE" {
  if (result.status === "failed") return "INFRA_FAILURE";

  const payload = result.payload;
  if (!payload || typeof payload !== "object") return "REVIEW";

  const outer = payload as Record<string, unknown>;
  const behavioral =
    outer.result && typeof outer.result === "object"
      ? (outer.result as Record<string, unknown>)
      : outer;

  switch (behavioral.merge_recommendation) {
    case "allow":
      return "ALLOW";
    case "block":
      return "BLOCK";
    case "review":
      return "REVIEW";
    default:
      return "REVIEW";
  }
}
