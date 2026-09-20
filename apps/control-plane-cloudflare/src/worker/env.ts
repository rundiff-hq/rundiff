export interface Env {
  DB: D1Database;
  ARTIFACTS: R2Bucket;
  REVIEW_WORKFLOW: Workflow;
  RUNDIFF_SPIKE_TOKEN?: string;
}
