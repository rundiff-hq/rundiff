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


## Completed proof

The external proof completed successfully on `rundiff-hq/example-node-express-postgres#1`.

### BLOCK pass

```text
candidate          193c81c0c188d8745d1bc8bcd895f262fbe33605
workflow run       35670043165
execution          f232ae1e-458c-4e87-9900-08b121ae89c8
baseline HTTP      200
candidate HTTP     500
decision           regression
merge recommendation block
submission         accepted
```

### Same-PR fix

```text
43cc658576779db6663a115c28564dc9b17f7401
fix: restore successful widgets response
```

### ALLOW pass

```text
workflow run       35670253369
execution          c302a4a7-bf15-47a9-a11f-ecfdf985ce97
baseline HTTP      200
candidate HTTP     200
decision           no_regression
merge recommendation allow
submission         accepted
```

This proves a real external Node + Express + PostgreSQL pull request can move through the RunDiff GitHub App, Cloudflare control plane, central Go executor, external repository workspace, npm bootstrap, Node HTTP sensor, behavioral comparison, and GitHub publication.

The proof uncovered and fixed two genuine external-repository defects:

1. Remote/local repository selection was incorrectly coupled to repository-capability token presence.
2. Fresh remote repository setup used a brittle `git remote add` path instead of idempotent remote configuration.

The canonical product story remains:

```text
BLOCK -> fix same PR -> ALLOW
```

Warnings are orthogonal findings, not a fourth decision state. See `docs/architecture/decision-and-finding-severity-v1.md`.
