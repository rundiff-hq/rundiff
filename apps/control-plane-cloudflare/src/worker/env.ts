export interface Env {
  DB: D1Database;
  ARTIFACTS: R2Bucket;
  REVIEW_WORKFLOW: Workflow;
  RUNDIFF_SPIKE_TOKEN?: string;
  RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN?: string;
}
