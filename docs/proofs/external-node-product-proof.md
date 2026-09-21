# External Node Product Proof

This proof exercises a real pull request outside the RunDiff repository.

Target:

```text
rundiff-hq/customer-rails-sandbox#6
base: fixture/node-express-postgres-base
candidate: demo/node-express-postgres-block
```

The baseline is a pure Node application using Express and PostgreSQL.

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

The workflow in this slice is an explicit product-proof runner. It closes the execution gap for the acceptance proof but is not yet the final automatic central dispatcher for arbitrary customer PRs.
