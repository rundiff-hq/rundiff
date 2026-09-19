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

The onboarding lab now produces the same review artifact and terminal rendering:

```bash
bin/lab run onboarding --case sqlite
```

Artifacts:

```text
tmp/lab/onboarding/sqlite/
  proof.log
  review.json
  review.txt
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
