# GitHub integration

One RunDiff run projects into several GitHub surfaces.

## PR comment

Concise human summary. Use GitHub-flavored Markdown and update one durable bot-owned comment instead of posting a new comment on every push.

## Check Run

Stable merge and agent state. The initial Actions check name is:

```text
RunDiff / Behavioral Diff
```

The Development GitHub App uses a distinct context while both delivery paths are dogfooded:

```text
RunDiff Development / Behavioral Diff
```

Behavioral decision mapping:

```text
allow  -> success
review -> neutral
block  -> failure
```

Execution infrastructure is a separate outcome and must never be presented as a product regression:

```text
infra_failure          -> failure
stale                  -> no publication for the stale execution
manual_review_required -> action_required
```

An `INFRA_FAILURE` Check says that RunDiff could not produce trustworthy behavioral evidence. The durable execution remains failed with `outcome=infra_failure` and may be re-run. It uses the failed Check conclusion so GitHub presents retry semantics instead of the manual `Resolve` flow reserved for `action_required`. A high or critical behavioral regression is not rerunnable as infrastructure and must not be silently accepted as a new baseline.

The check uses the RunDiff execution/run identity as `external_id`. For App-native executions, `check_run.rerequested` resolves that external ID back to the durable `RunDiffExecution`. RunDiff only requeues the check when the execution outcome is `infra_failure` and the PR still points at the exact recorded base and head. Each successful claim increments `attempt_count`; stale or behavioral outcomes are not re-run through the infrastructure retry path.

GitHub Actions may assign its own Check Run page as `details_url`, so the output summary also carries an explicit link to the Actions execution. GitHub presents the latest `RunDiff / Behavioral Diff` context for the current head; internal Check Run IDs may differ across workflow attempts.

## Annotations

Annotations are deliberately conservative. A finding is source-localized only when runtime evidence provides a trustworthy source and the attributed path is present in the exact `base...head` changed-file set.

RunDiff currently recognizes two trusted source modes:

```text
explicit -> an integration supplied an exact source location
runtime  -> RunDiff captured an application callsite while the signal occurred
```

Trust order is conservative:

```text
changed explicit source
        ↓
changed single runtime source
        ↓
otherwise no source annotation
```

An explicit source always wins. Automatic runtime attribution is accepted only when exactly one changed-code runtime location exists for the finding. If multiple runtime callsites are plausible, the regression still affects the Check conclusion and PR comment, but RunDiff does not guess which line to blame.

```text
runtime evidence
      +
changed-file proof
      +
unambiguous source
      ↓
finding.source
      ↓
GitHub annotation
```

### Rails runtime sources

`RunDiff::Rails::SourceLocator` is the shared project-callsite primitive for synchronous Rails signals. It excludes RunDiff internals and dependency/runtime paths such as `vendor/`, `tmp/`, `.bundle/`, `log/`, and `storage/`, then returns the first application-owned frame.

Current automatic integrations:

```text
sql.active_record       -> SQL execution site
enqueue.active_job      -> background-job enqueue site
enqueue_at.active_job   -> scheduled-job enqueue site
deliver.action_mailer   -> synchronous email delivery site
request.net_http.rundiff  -> outbound Net::HTTP request site
```

`http_requests` now means outbound application network calls, not the inbound Rails action used to invoke a RunDiff scenario. `process_action.action_controller` remains useful for detecting action exceptions, but it no longer increments the HTTP side-effect count.

The initial outbound adapter instruments `Net::HTTP#request`. It covers direct stdlib usage and libraries that execute through Net::HTTP. It does not claim universal Ruby HTTP coverage. Other transports such as HTTPX, Excon, or adapters that bypass Net::HTTP should publish equivalent evidence through their own RunDiff adapter or through a future OpenTelemetry ingestion path.

The captured runtime source means "where this observed behavior happened". It is not necessarily the root cause of why a PR changed the behavior. For example, a changed configuration or loop count can create an extra job or request while the runtime source correctly points to an unchanged `perform_later` or `Net::HTTP` call. Future causal analysis may connect runtime sites to changed-code cause candidates, but GitHub annotations must not claim that inference today.

Background-job count changes currently produce a medium-severity `SIDE_EFFECT_CHANGED` finding, so their default merge recommendation is `REVIEW` rather than `BLOCK`. Generic outbound HTTP count changes are also medium severity today and use `NETWORK_BEHAVIOR_CHANGED`; a trusted runtime request source can produce a warning annotation on the neutral Check. Future method-, host-, and endpoint-aware policy can distinguish a repeated idempotent GET from a repeated payment or webhook POST.

Synchronous email count changes remain high severity and default to `BLOCK`.

This instrumentation is intended for RunDiff executions such as CI and test environments, not as an always-on production profiler by default.

`RunDiff::Rails::Evidence.attribute_next_line` remains a low-level explicit override. Keep the call on one physical line and place it immediately above the causal line that should receive the annotation. For integrations that already know the exact location, prefer `RunDiff::Rails::Evidence.attribute(..., line:)`.

## Agent contract

Agents should never be required to parse the PR comment, Check Run, or annotations. Publish a versioned result JSON and later expose the same model through API/MCP.

```text
PR comment -> What changed?
Check      -> Can this merge?
Annotation -> Where is a confidently attributed runtime source?
RunDiff UI -> Why did it happen?
API/MCP    -> What should an agent do next?
```


## Repository configuration onboarding

Planned hosted onboarding keeps repository file contents read-only from the RunDiff App.

Canonical configuration is:

~~~text
/rundiff.yml
~~~

The control panel acts as a visual editor for repository-owned configuration.

Preferred flow:

~~~text
configure in RunDiff UI
  -> preview rundiff.yml
  -> Open configuration on GitHub
  -> authenticated user reviews file
  -> user creates branch/commit
  -> user opens PR against default branch
~~~

RunDiff should not request permanent repository Contents: write merely to create or update this file.

The normal happy path should not require manual copy/paste. GitHub browser URL generation must be encapsulated because undocumented prefill query parameters are not a durable API contract.

The committed repository revision remains the source of truth. A SaaS-side draft must not silently override the checked-in file.

See RFC 0007.

## Workload discovery boundary

The control plane should not clone private source merely to enumerate tests.

Preferred path:

~~~text
short-lived read capability
  -> execution environment
       -> clone
       -> discover tests/scenarios
       -> emit derived catalog
       -> cleanup
  -> control plane
~~~

Catalog metadata such as test names, paths, tags, and duration estimates is still customer data.

See RFC 0007.

## Ownership-aware routing

GitHub remains the primary review surface, but findings may later route to the owning team.

CODEOWNERS is the preferred first ownership source.

Ownership does not imply causality.

A finding may carry explainable ownership context such as:

~~~text
@acme/api
  reason: owns changed source

@acme/payments
  reason: owns affected scenario
~~~

External Slack, Teams, Discord, Telegram, email, webhook, incident, or agent delivery is policy-controlled.

Infrastructure failures should route to CI/RunDiff operations ownership rather than application CODEOWNERS by default.

See RFC 0008.
