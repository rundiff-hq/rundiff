# RFC 0002: Runner adapter contract

Status: Draft

> Terminology note: this RFC predates the infrastructure taxonomy in RFC 0004. Here, "runner adapter" means an execution/driver adapter around a customer framework or command. It does not mean the infrastructure Runner Backend role in an Execution Plan. New infrastructure code should avoid using the bare term "runner" when the distinction matters.

A runner adapter may:

1. start an execution;
2. inject correlation context;
3. run the customer's framework or command;
4. collect native status and artifacts;
5. publish normalized measurements;
6. finalize execution.

Examples:

~~~text
Playwright -> trace + browser/network evidence
Capybara   -> test result + Rails/browser evidence
Maestro    -> mobile flow + screenshots/video/device samples
CLI        -> exit/stdout/stderr/time/RSS/profile
k6         -> load metrics + traces
~~~

Non-goal: define a universal click/fill/assert DSL.

See RFC 0004 for Execution Plan, Execution Orchestrator, Compute Provider, Runner Backend, runtime/isolation, resources, parallelism, and placement terminology.
