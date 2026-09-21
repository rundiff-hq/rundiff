# External Node Product Proof

This proof exercises a real pull request outside the RunDiff repository.

Target:

```text
rundiff-hq/example-node-express-postgres#1
base: main
candidate: demo/http-regression
```

The baseline is a dedicated public pure Node application using Express and PostgreSQL.

The candidate still performs the PostgreSQL query but intentionally changes the scenario response from HTTP 200 to HTTP 500.

Expected first result:

```text
GitHub App webhook
-> Cloudflare control plane
-> exact execution
-> central Go executor
-> external repository capability
-> npm ci
-> Node service
-> Node HTTP sensor
-> Go comparison
-> BLOCK
```

After that proof, the same PR branch is repaired to return HTTP 200 and the exact flow must produce ALLOW.

The workflow in this slice is an explicit product-proof runner. It resolves the execution created by the RunDiff GitHub App webhook, then runs the production Go agent centrally. It is not yet the final automatic central dispatcher for arbitrary customer PRs.

Trigger note: the branch-push runner exists only to complete this live acceptance proof before automatic cross-repository dispatch is productized.
