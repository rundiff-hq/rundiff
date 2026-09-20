# Local Codex + Cloudflare runbook

This runbook gives local Codex CLI access to the RunDiff repository plus Cloudflare through Wrangler and Cloudflare MCP.

## 1. Checkout the current implementation branch

~~~bash
git clone git@github.com:rundiff-hq/rundiff.git
cd rundiff
git fetch origin
git checkout feat/cloudflare-control-plane-v1
~~~

If the repository already exists:

~~~bash
cd /path/to/rundiff
git fetch origin
git checkout feat/cloudflare-control-plane-v1
git pull --ff-only
~~~

## 2. Install/upgrade Codex CLI

~~~bash
npm install -g @openai/codex
codex --version
~~~

Run Codex from the repository root so it sees repository instructions and the Cloudflare app.

## 3. Install the Cloudflare Codex plugin

Start Codex:

~~~bash
codex
~~~

Inside Codex:

~~~text
/plugins
~~~

Search for **Cloudflare** and install it.

The Cloudflare plugin installs Cloudflare Skills and registers Cloudflare MCP servers.

If the plugin path is unavailable or MCP is not connected, configure the Cloudflare API MCP explicitly:

~~~bash
codex mcp add cloudflare --url https://mcp.cloudflare.com/mcp
codex mcp list
~~~

Inside Codex, use:

~~~text
/mcp
~~~

to inspect MCP status.

The first Cloudflare MCP action should open an OAuth authorization flow. Grant only the permissions needed for RunDiff.

Optional documentation MCP:

~~~bash
codex mcp add cloudflare-docs --url https://docs.mcp.cloudflare.com/mcp
~~~

Optional observability MCP, useful after deployment:

~~~bash
codex mcp add cloudflare-observability --url https://observability.mcp.cloudflare.com/mcp
~~~

## 4. Install project dependencies

~~~bash
cd apps/control-plane-cloudflare
npm install
npx wrangler --version
~~~

Wrangler is intentionally project-local. Prefer `npx wrangler` instead of depending on a global Wrangler install.

## 5. Authenticate Wrangler

For a single personal account, either:

~~~bash
npx wrangler login
~~~

or, when callback login is inconvenient:

~~~bash
npx wrangler login --device
~~~

If you use multiple Cloudflare accounts, prefer a named profile:

~~~bash
npx wrangler auth create rundiff
npx wrangler auth activate rundiff "$(pwd)"
npx wrangler auth list
~~~

After the correct account is known, put its non-secret `account_id` into the local `wrangler.jsonc`. Pairing an auth profile with an explicit account ID reduces the risk of operating on the wrong account.

Do not paste OAuth/API tokens into Codex prompts.

For CI later, use a scoped `CLOUDFLARE_API_TOKEN`; local interactive work should prefer OAuth/profile.

## 6. Verify Cloudflare access without printing credentials

From `apps/control-plane-cloudflare`:

~~~bash
npx wrangler auth token --json >/dev/null
npx wrangler d1 list
npx wrangler r2 bucket list
npx wrangler workflows list
~~~

These are read-only preflight operations.

Do not run `wrangler auth token` without redirecting/capturing it in agent logs.

## 7. Run the repository preflight

From the repository root:

~~~bash
bash apps/control-plane-cloudflare/bin/codex-cloudflare-preflight
~~~

The preflight does not create or delete Cloudflare resources.

## 8. Run Codex

From repository root:

~~~bash
codex
~~~

Use the prompt in:

~~~text
prompts/codex-cloudflare-vs1.md
~~~

For production account work, prefer normal approvals/workspace-write rather than unrestricted sandbox bypass. Approve Cloudflare mutations intentionally.

## 9. Resource names reserved for VS1

Use these stable names unless existing account state requires a documented reason to differ:

~~~text
Worker     rundiff-control-plane
D1         rundiff-control-plane
R2         rundiff-artifacts
Workflow   rundiff-behavioral-review
~~~

Inspect before create.

## 10. DNS stop line

Do not bind a custom domain or change DNS until the authoritative RunDiff production domain has been explicitly confirmed.

The repository contains historical references to `rundiff.com`; prior conversation also surfaced `rundiv.com`. Treat this as unresolved until explicitly confirmed.

## Useful Cloudflare commands

~~~bash
# Worker
npx wrangler deploy
npx wrangler versions list

# D1
npx wrangler d1 list
npx wrangler d1 migrations list rundiff-control-plane
npx wrangler d1 migrations apply rundiff-control-plane --local
npx wrangler d1 migrations apply rundiff-control-plane --remote

# R2
npx wrangler r2 bucket list

# Workflows
npx wrangler workflows list
npx wrangler workflows describe rundiff-behavioral-review

# Logs after deploy
npx wrangler tail
~~~

Always check `--help` before destructive/uncertain commands.
