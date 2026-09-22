import { GitHubClient, type GitHubCredentials } from "./client";
import type { ExecutorRequestV1 } from "../../domain/executor";

export interface ExecutorDispatchEnv extends GitHubCredentials {
  RUNDIFF_EXECUTOR_DISPATCH_REPOSITORY?: string;
  RUNDIFF_EXECUTOR_DISPATCH_WORKFLOW?: string;
  RUNDIFF_EXECUTOR_DISPATCH_REF?: string;
}

const DEFAULT_REPOSITORY = "rundiff-hq/rundiff";
const DEFAULT_WORKFLOW = "rundiff-executor-bridge.yml";
const DEFAULT_REF = "main";

export async function dispatchExecutor(
  env: ExecutorDispatchEnv,
  request: ExecutorRequestV1,
): Promise<void> {
  const repository =
    env.RUNDIFF_EXECUTOR_DISPATCH_REPOSITORY ?? DEFAULT_REPOSITORY;
  const workflow =
    env.RUNDIFF_EXECUTOR_DISPATCH_WORKFLOW ?? DEFAULT_WORKFLOW;
  const ref = env.RUNDIFF_EXECUTOR_DISPATCH_REF ?? DEFAULT_REF;
  const customerRepository = request.context.repository;
  if (!customerRepository) throw new Error("executor request repository is required");

  const github = await GitHubClient.repositoryInstallation(
    env,
    repository,
    { actions: "write" },
  );
  await github.dispatchWorkflow(repository, workflow, ref, {
    execution_id: request.execution_id,
    attempt_number: String(request.attempt_number),
    repository: customerRepository,
    candidate_sha: request.candidate_sha,
  });
}
