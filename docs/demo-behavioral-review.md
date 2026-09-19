# Behavioral Review v1 demo

RunDiff's demo contract is intentionally simple:

```text
plain Rails app
  -> candidate-only rundiff.yml
  -> exact baseline/candidate execution
  -> runtime evidence
  -> one Behavioral Review payload
       -> terminal
       -> GitHub Check
       -> GitHub PR comment
```

## One-command wow demo

Prepare the RunDiff repository once:

```bash
bundle install
bin/rails db:prepare
```

Then run the complete customer-like proof and render it immediately:

```bash
bin/rundiff demo --color always
```

That one command creates a plain temporary Rails + SQLite subject, commits a clean baseline and a candidate with a deliberate SQL regression plus candidate-only `rundiff.yml`, executes both exact Git revisions, captures runtime evidence, and renders the resulting Behavioral Review.

Persist the raw review payload for inspection or recording:

```bash
bin/rundiff demo \
  --color always \
  --output tmp/demo/block.json
```

The same one-command demo can render GitHub Markdown or JSON:

```bash
bin/rundiff demo --format markdown
bin/rundiff demo --format json
```

Use it as a shell gate when desired:

```bash
bin/rundiff demo --fail-on-block
```

## Manual local wow demo

Prepare the RunDiff repository once:

```bash
bundle install
bin/rails db:prepare
mkdir -p tmp/demo
```

Run the real Rails + SQLite customer proof and persist its review payload:

```bash
RUNDIFF_OUTPUT=tmp/demo/block.json \
  bundle exec ruby script/prove_rails_sqlite_subject.rb
```

Render the product-facing terminal review:

```bash
bin/rundiff review --input tmp/demo/block.json
```

Force colors when recording a demo from a non-TTY shell:

```bash
bin/rundiff review \
  --input tmp/demo/block.json \
  --color always
```

Render the same evidence as GitHub-flavored Markdown:

```bash
bin/rundiff review \
  --input tmp/demo/block.json \
  --format markdown
```

Inspect the stable machine-readable source:

```bash
bin/rundiff review \
  --input tmp/demo/block.json \
  --format json
```

Use shell exit status as a gate when wanted:

```bash
bin/rundiff review \
  --input tmp/demo/block.json \
  --fail-on-block
```

The deliberate SQLite regression should show a functional pass plus a blocking `DATABASE_QUERY_REGRESSION`.

## One-command proof

The onboarding lab now executes the exact one-command demo path and preserves the same review artifact and terminal rendering:

```bash
bin/lab run onboarding --case sqlite
```

Artifacts:

```text
tmp/lab/onboarding/sqlite/
  proof.log
  review.json
  review.txt
  payload-proof.log
  result.env
```

## Remote Linux proof

Run the same onboarding proof on an ephemeral GitHub-hosted runner:

```bash
gh workflow run lab-group.yml \
  --repo rundiff-hq/rundiff \
  --ref main \
  -f group=onboarding
```

Then inspect the `lab-group-onboarding-...` artifact.

## Hermetic GitHub App proof

The Production Lab uses Vercel Labs `emulate` as the GitHub system of record for its customer-shaped integration proof. The driver creates branches, candidate-only `rundiff.yml`, and pull requests through the emulator's GitHub API. The emulator originates the `pull_request` webhook, RunDiff receives it through the normal signed webhook boundary, executes through the remote executor, and publishes the resulting Check Run and durable PR comment back through the App API.

This is the canonical automated GitHub integration path:

```text
GitHub emulator PR event
  -> emulator-originated signed webhook
  -> RunDiff control plane
  -> remote executor
  -> GitHub Check + PR comment
```

`bin/replay-github-pr` remains an operator/recovery tool and an additional same-org proof. The Production Lab does not depend on replay to prove that an ordinary PR event can trigger a Behavioral Review.

The hermetic acceptance also proves the customer-shaped correction loop on one pull request:

```text
open PR
  -> emulator-originated pull_request webhook
  -> BLOCK / DATABASE_QUERY_REGRESSION
push fix to the same PR branch
  -> emulator-originated pull_request synchronize webhook
  -> ALLOW
```

The second review must be attached to the new head of the same PR. No replay command or manually synthesized webhook drives this transition.

## Read-only installed-App preflight

Before re-driving the sandbox PRs, verify that the target repository is actually ready for the hosted flow:

```bash
bin/verify-github-app-demo \
  rundiff-hq/customer-rails-sandbox \
  --regression-pr 4 \
  --neutral-pr 5
```

The preflight is read-only. It verifies the repository allowlist, App authentication, actual repository installation, remote executor mode, both current open PRs, a shared baseline, and candidate-only `rundiff.yml` on both candidates.

Expected final markers:

```text
github_app_demo_preflight=passed
executor_mode=remote
candidate_only_rundiff_config=verified
```

## Prove BLOCK + ALLOW with one installed-App command

For the canonical customer-like sandbox, run both proof PRs through the installed GitHub App with one command:

```bash
bin/prove-github-app-demo \
  rundiff-hq/customer-rails-sandbox \
  --regression-pr 4 \
  --neutral-pr 5 \
  --wait 1200 \
  --color always \
  --output tmp/github-app-demo.json
```

The command replays both current PRs through the signed webhook boundary, waits for their durable executions, renders both Behavioral Reviews, requires the first outcome to be `BLOCK` and the second to be `ALLOW`, and optionally persists a small machine-readable proof bundle.

Expected final markers:

```text
github_app_demo_regression=BLOCK
github_app_demo_neutral=ALLOW
github_app_demo=passed
```

This is the preferred same-org preproduction demo. The external-account acceptance still uses the stricter production proof bundle and remains a separate criterion.

## GitHub App demo target

The customer-facing repository should contain only the candidate-side RunDiff configuration:

```yaml
version: 1
scenario:
  path: /__rundiff/demo/behavior
subject:
  persistence: auto
```

The intended visible result is:

```text
Tests                         PASS
RunDiff / Behavioral Review  BLOCK

SQL queries                   baseline -> candidate
DATABASE_QUERY_REGRESSION
Functional scenario           PASSED
```

A neutral PR should render the same review surface with `ALLOW`.

The hosted public-App flow is the production promotion of this exact demo, not a separate execution model.


## Replay a real installed GitHub PR

Once the RunDiff GitHub App is installed on a repository, an operator can replay an existing current pull request through the **real signed webhook boundary** without creating another commit.

This is useful for the customer-like sandbox before the final cross-account production proof:

```bash
bin/replay-github-pr \
  rundiff-hq/customer-rails-sandbox \
  4 \
  --wait 1200 \
  --color always
```

Expected result for the deliberate regression PR:

```text
review_delivery=accepted
...
execution_status=completed
execution_outcome=block

RunDiff Behavioral Review
✕ BLOCK
...
DATABASE_QUERY_REGRESSION
```

The neutral counterpart is:

```bash
bin/replay-github-pr \
  rundiff-hq/customer-rails-sandbox \
  5 \
  --wait 1200 \
  --color always
```

Expected outcome: `allow`.

The replay command:

- resolves the repository's installation through the configured RunDiff GitHub App;
- mints a short-lived installation token;
- fetches the current pull-request head/base;
- creates a correctly signed `pull_request/synchronize` delivery;
- posts it to the normal `/github/webhooks` endpoint;
- does **not** bypass `RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST`;
- never needs an operator PAT;
- never prints the installation token or webhook secret;
- optionally waits on the durable control-plane execution and renders the same Behavioral Review in the terminal.

For production, run the command from an environment connected to the same control-plane database and configured with the same App credentials and webhook secret. `--url` may override the webhook endpoint when needed.
