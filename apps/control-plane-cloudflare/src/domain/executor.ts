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

export function validateExecutorRequest(value: unknown): ExecutorRequestV1 {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("executor request must be an object");
  }

  const request = value as Record<string, unknown>;
  if (request.schema_version !== "1") {
    throw new Error("unsupported executor request schema");
  }

  const requiredString = (key: string): string => {
    const field = request[key];
    if (typeof field !== "string" || field.length === 0) {
      throw new Error(`executor request ${key} must be a non-empty string`);
    }
    return field;
  };

  const attemptNumber = request.attempt_number;
  if (
    typeof attemptNumber !== "number" ||
    !Number.isSafeInteger(attemptNumber) ||
    attemptNumber < 1
  ) {
    throw new Error("executor request attempt_number must be a positive integer");
  }

  const rawContext = request.context;
  if (!rawContext || typeof rawContext !== "object" || Array.isArray(rawContext)) {
    throw new Error("executor request context must be an object");
  }
  const source = rawContext as Record<string, unknown>;
  const context: ExecutorRequestV1["context"] = {};

  const optionalString = (
    key: "repository" | "baseline_ref" | "candidate_ref" | "candidate_repository",
  ): string => {
    const field = source[key];
    if (typeof field !== "string" || field.length === 0) {
      throw new Error(`executor request context.${key} must be a non-empty string`);
    }
    return field;
  };

  if ("repository" in source) context.repository = optionalString("repository");
  if ("baseline_ref" in source) context.baseline_ref = optionalString("baseline_ref");
  if ("candidate_ref" in source) context.candidate_ref = optionalString("candidate_ref");
  if ("candidate_repository" in source) {
    context.candidate_repository = optionalString("candidate_repository");
  }
  if ("pull_request_number" in source) {
    const number = source.pull_request_number;
    if (
      typeof number !== "number" ||
      !Number.isSafeInteger(number) ||
      number < 1
    ) {
      throw new Error(
        "executor request context.pull_request_number must be a positive integer",
      );
    }
    context.pull_request_number = number;
  }

  return {
    schema_version: "1",
    execution_id: requiredString("execution_id"),
    scenario_id: requiredString("scenario_id"),
    baseline_sha: requiredString("baseline_sha"),
    candidate_sha: requiredString("candidate_sha"),
    attempt_number: attemptNumber,
    context,
  };
}

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
