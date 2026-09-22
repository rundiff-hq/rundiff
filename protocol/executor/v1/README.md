# Executor protocol v1

This directory is the canonical machine-readable compatibility boundary between the RunDiff control plane and replaceable executors.

## Rules

- `schema_version` is exactly `"1"`.
- Request v1 is executor-portable but its optional context is currently GitHub-oriented.
- Provider credentials, installation IDs, webhook delivery IDs, and repository clone capabilities are never serialized into Request v1 or Result v1.
- Readers ignore unknown fields so additive producer changes do not break older workers.
- Request producers emit the complete identity envelope.
- Result producers emit `payload`, `error_class`, and `error_message`; readers treat omitted optional result fields as null for compatibility.
- The control plane owns stale checks, leases, cancellation, policy, decisions, and publication.
- The executor owns execution and evidence production for one exact `execution_id + attempt_number`.
- The historical nested `payload.result.merge_recommendation` remains a v1 compatibility shape; it is not the long-term policy boundary.

The Ruby reference implementation and the Cloudflare TypeScript implementation must both pass the fixtures in `fixtures/`. The managed Go executor must pass the same fixtures before replacing the Ruby reference executor.
