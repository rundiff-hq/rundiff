# Customer code execution boundary

RunDiff intentionally executes customer repository code only inside the executor trust boundary. The control plane authenticates GitHub events, owns durable execution state and policy, mints short-lived repository capabilities, and publishes results; it does not run customer code.

## Explicit process services

`subject.services` may declare supporting processes needed by a behavioral capture. The supported process runtimes remain intentionally narrow:

- service type is `process`
- runtime is explicitly `ruby` or `node`
- Ruby uses executor-owned `RbConfig.ruby`; Node uses the executor-owned fixed `node` executable
- customer configuration cannot select an arbitrary executable or shell command
- `SetupPlanCompiler` requires the requested runtime to be declared by executor runtime capabilities before the service can be planned
- the entrypoint is repository-relative and its real path must resolve to a file inside the disposable checkout
- arguments are passed as argv; no shell expansion is used
- the executor assigns the listening port and exports the resulting service URL
- readiness is bounded HTTP or TCP polling and capture starts only after readiness succeeds
- services are terminated before subject-state cleanup, including readiness and capture failures

The executor inherits only a small allowlist of host environment variables. A configured service URL cannot overwrite an existing capture environment value.

Adding another runtime must be implemented as another reviewed executor-owned provider. It must not turn `subject.services` into a generic command or shell DSL.

## Subject execution privilege boundary

The production executor retains its operating-system identity for executor-owned control operations such as Git/worktree management and installation of the selected Bundler tool version. Repository-controlled code does not execute with that identity.

The production image declares an explicit subject identity (`RUNDIFF_SUBJECT_UID`, `RUNDIFF_SUBJECT_GID`, `RUNDIFF_SUBJECT_HOME`, and `RUNDIFF_SUBJECT_USER`) backed by the dedicated `rundiff-subject` account. RunDiff assigns each disposable checkout/state directory to that identity and uses it for every customer-controlled execution phase:

- Bundler evaluation/install of the customer Gemfile and locked dependencies
- npm/pnpm/Yarn/Bun dependency installation and their lifecycle scripts
- Rails persistence preparation, including application code loaded by `db:prepare`
- explicit Ruby/Node process services
- the behavioral capture process
- descendants of capture, including subject-owned workers

The only Bundler operation allowed to remain executor-owned is selecting/installing the **Bundler tool itself** from the exact `BUNDLED WITH` version. Customer Gemfile evaluation still occurs only through the subject runner.

`USER` and `LOGNAME` are identity-owned and override repository/capture environment attempts to replace them. The declared account home is metadata for the OS account; customer execution instead receives a worktree-local `tmp/rundiff/home`, also enforced after caller environment merging. Local development remains unchanged when no subject identity is declared. An enabled subject identity must use a positive UID different from the executor UID and an absolute account home path; a configuration that collapses the two identities fails closed.

Writable dependency state is isolated. When the production subject identity is enabled, Ruby bundle cache state and runtime `HOME` are worktree-local rather than mutable state shared by baseline and candidate. JavaScript dependency state is created inside each disposable worktree as well.

Baseline and candidate are also activated sequentially. The execution parent directory remains executor-owned and non-writable to the subject identity. Before one side runs, only that worktree and its pre-created output file are assigned to the subject UID/GID. The sibling worktree remains executor-owned with mode `0700`. After lifecycle/capture finishes or fails, the output and worktree are sealed back to the executor before the other side is activated. This prevents baseline and candidate from sharing writable filesystem or home-directory state even though they use the same subject UID.

This privilege split is a prerequisite for the isolated container-service provider. Provider authority can remain readable by the executor authority boundary while being inaccessible to customer setup/runtime code. The production build proof creates root-only authority material, proves a customer command and a real HTTP process service execute as the subject UID/GID and cannot read it, proves baseline/candidate cannot cross-read each other's sealed workspace or share `HOME`, and verifies recursive workspace ownership does not change a symlink target outside the workspace.

## Explicit Compose services

Compose is a separate service-provider capability, not another process runtime. A repository may explicitly select a single Compose image service with a repository-contained manifest, target port, exported URL scheme/env, and bounded readiness probe.

The first Compose provider is deliberately restrictive:

- `compose.yml` is never auto-started merely because it exists
- `SetupPlanCompiler` requires an executor-declared `service_providers.compose` capability
- only the explicitly selected service is started
- the provider uses `docker compose run --no-deps`; it does not start the whole project
- the provider owns port publishing and binds one target port to an ephemeral `127.0.0.1` host port
- customer `ports` are not used
- manifests with `build`, volumes/bind mounts, dependency graphs, host networking, devices, added capabilities, privileged mode, external networking, or other unreviewed service keys are rejected by the strict manifest admission profile
- the selected service must use an image; arbitrary host commands are not introduced
- host environment inheritance is allowlisted before Compose interpolation and execution
- teardown removes the one-off container and the unique Compose project network/resources

The host-capable Compose proof runs a real Redis image, waits for TCP readiness, verifies `PING -> PONG`, then proves the container, project network, and endpoint are gone after lifecycle teardown.

## Production Compose isolation

The current remote production executor intentionally does **not** declare the Compose service-provider capability and does not contain the Docker CLI. Its container is not given `/var/run/docker.sock`.

This is a security boundary, not a missing convenience flag. Giving customer code direct Docker daemon access would let it attempt to control the Docker host. Production Compose therefore remains fail-closed until RunDiff has a separate isolated sandbox/service-provider boundary that can hold container-management authority without exposing it to the `rundiff-subject` execution identity.

The production Docker build contains an invariant that fails if `service_providers.compose` is accidentally declared or the Docker CLI becomes available in the current executor image.

## Runtime capability boundary

A repository declaration does not prove that a runtime or service provider exists or authorize an executor to use it. `RuntimeCapabilities` is the executor-side authority. `SetupPlanCompiler` fails closed when a service requests a runtime or service provider that the current executor has not declared.

The production image declares its Node version in `RUNDIFF_EXECUTOR_CAPABILITIES_JSON`. The Docker build proof compares that declaration with `node --version`, then runs a real Node HTTP service through `rundiff.yml -> Configuration -> SetupPlanCompiler -> ServiceExecutor -> Lifecycle`, including dynamic port assignment, readiness, capture, process teardown, and state cleanup.

## Credential and persistence boundary

Executor deployments must not receive the GitHub App private key or webhook secret. Private-repository access uses a separate short-lived, repository-scoped, contents-read capability. That capability is consumed by the disposable repository adapter and is not serialized into the stable Request/Result contracts or persisted in the executor request ledger.

Production Lab and the remote-executor topology proof exercise these boundaries, including service readiness/teardown, control-plane/executor secret separation, Request v1 dispatch, and repository-capability non-persistence.

## Static-analysis exception policy

Brakeman reports each intentional `Process.spawn` provider boundary as an `Execute` command-injection warning even though the executable is executor-owned and no shell is involved. RunDiff does not disable the `Execute` check. `config/brakeman.ignore` suppresses only the individually reviewed Ruby and Node warning fingerprints for `RunDiff::Subject::ServiceExecutor#start_process`, with a threat-model note for each provider.

`config/brakeman.yml` requires every ignored warning to have a note and fails CI when an ignore entry becomes obsolete. A code change that alters either execution boundary therefore produces a new fingerprint or an obsolete suppression and requires explicit review instead of silently inheriting the exception.
