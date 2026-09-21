# Implementation Plan 0014: Dependency Cache v1

## Goal

Make dependency caching an explicit runtime-neutral executor capability and persist it across ephemeral GitHub Actions executions without changing Sensor Protocol v1 or Executor Protocol v1.

## Findings

The Go migration did not remove caching. VS4 already introduced a lock-digest Bundler directory shared by baseline/candidate inside one executor workspace. VS6 production evidence showed why this matters:

~~~text
cold baseline Bundler bootstrap   32.895 s
warm candidate bootstrap           0.316 s
~~~

The remaining gap is persistence and a common identity model. The current Bundler cache is local to the checkout/tool root, while the Node v1 path runs npm ci without an executor-owned npm cache directory.

## Cache identity

Dependency Cache v1 derives an entry from:

~~~text
trust namespace (repository/tenant)
runtime
runtime version
package manager
package manager version
OS
architecture
lockfile SHA-256
~~~

The filesystem directory uses a hash of that identity. The complete identity remains observable in bootstrap environment metadata.

## Runtime behavior

### Ruby / Bundler

- preserve frozen/deployment mode;
- use the dependency-cache entry as BUNDLE_PATH/BUNDLE_APP_CONFIG;
- run bundle check first;
- install only on miss;
- record hit/miss accurately;
- include Bundler version, OS, and architecture in the identity.

### Node / npm

- continue requiring committed package-lock.json;
- run npm ci;
- point npm's content-addressed download cache at the executor dependency-cache entry;
- prefer offline cache data when available;
- never treat cached node_modules/customer workspace as authoritative;
- preserve package.json and package-lock.json digests.

## Placement

Default local root:

~~~text
<tool-root>/tmp/rundiff/dependency-cache/v1
~~~

Override:

~~~text
RUNDIFF_DEPENDENCY_CACHE_ROOT=/persistent/path
RUNDIFF_DEPENDENCY_CACHE_NAMESPACE=owner/repository
~~~

Managed/BYOC hosts can mount that path on persistent local storage. Multi-tenant hosts must scope prepared dependency entries by repository/tenant namespace.

GitHub Actions restores/saves the same directory with actions/cache. Internal entry identities remain authoritative, so a broad Actions restore key cannot cause incompatible dependency reuse.

## Metrics / evidence

Bootstrap environment exposes:

~~~text
RUNDIFF_DEPENDENCY_CACHE_KEY
RUNDIFF_DEPENDENCY_CACHE_ROOT
RUNDIFF_DEPENDENCY_CACHE_SEED=hit|miss
~~~

Existing phase timing remains the source of duration evidence.

## Acceptance

- common content-addressed identity helper;
- Ruby same identity shares cache and reports hit/miss;
- Ruby identity changes with Bundler/platform/lock identity;
- Node uses executor-owned npm cache and deterministic npm ci;
- Node same identity shares npm artifact cache;
- GitHub Actions bridge persists dependency-cache root;
- paired benchmark can persist the same cache root when desired;
- full Rails bridge, Node sensor tests, Production Lab, and Compose proof remain green.
