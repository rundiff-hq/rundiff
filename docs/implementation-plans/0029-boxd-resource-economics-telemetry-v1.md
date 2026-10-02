# Implementation Plan 0029: Boxd Resource Economics Telemetry v1

Status: in progress

Tracking issue: #242

## Goal

Replace the largest Boxd assumptions in provider economics v1 with measured
RunDiff-specific resource evidence for the canonical Node/PostgreSQL fixture.

This slice does not claim to reproduce Boxd invoice counters.

## Measurement boundary

Boxd's public rate card bills:

- CPU by running vCPU time;
- RAM by actual resident memory;
- disk by actual written bytes.

The current public SDK/docs do not expose a provider-side usage counter that
RunDiff can query in this proof.

Therefore every resource number in this slice is explicitly:

~~~text
guest_observed_proxy_not_provider_billing
~~~

The artifact must retain that label.

## Fixture

~~~text
repository: rundiff-hq/example-node-express-postgres
baseline:   e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb
candidate:  a1663f54380e3a117989ebc6f1ab8f525f6bed4e
~~~

The execution path is the BOXD6 collapsed path:

- one persistent prepared golden;
- PostgreSQL already running;
- parallel pair fork;
- parallel role capture;
- same Capture v1 / Result v1;
- expected BLOCK / NEW_RUNTIME_ERROR.

## Guest resource snapshot

The pinned helper records:

- /proc MemTotal and MemAvailable;
- memory-used proxy = MemTotal - MemAvailable;
- sum of visible process VmRSS;
- cgroup v2 memory.current when present;
- root filesystem used bytes;
- repo size;
- node_modules size;
- Docker root size for detailed golden snapshots;
- PostgreSQL container writable-layer size;
- PostgreSQL rootfs size;
- PostgreSQL data-volume size.

The golden takes detailed snapshots before and after all samples.

Each child takes a resource snapshot while both PostgreSQL and the
revision-specific Node app are active, before the RunDiff sensor scenario is
captured.

## Lifecycle evidence

For five repeated executions record:

- fork start timestamp;
- pair-ready timestamp;
- capture start/end timestamps;
- cleanup start/end timestamps;
- fork-ready duration;
- baseline/candidate role durations;
- role critical path;
- cleanup duration;
- total duration.

These are RunDiff-observed lifecycle boundaries. They are not presented as the
provider's billing start/end timestamps.

## Helper provenance

The golden downloads the resource helpers from the exact
RUNDIFF_BOXD_TOOL_SHA used by the live proof:

~~~text
apps/executor-go/internal/compute/boxd/testdata/resource_snapshot.py
apps/executor-go/internal/compute/boxd/testdata/resource_role_capture.sh
~~~

The child VMs inherit those exact helper files through the fork.

## Output

~~~text
tmp/rundiff/boxd-resource-economics.json
~~~

The report contains:

- measurement kind + billing caveat;
- golden before/after snapshots;
- five raw paired samples;
- both role snapshots per sample;
- median/min/max resource and lifecycle summaries.

It is uploaded as a 14-day GitHub Actions artifact.

## Security

No environment dump, process argv dump, repository credentials, tokens or
customer payloads are recorded.

Only aggregate resource counters and known fixture identities are emitted.

## Acceptance

- five successful paired executions;
- every execution preserves BLOCK / NEW_RUNTIME_ERROR;
- resource snapshot taken with Node + PostgreSQL active in both roles;
- golden snapshots before and after;
- raw JSON artifact;
- summary median/range for child resource proxies;
- lifecycle timestamps and durations;
- explicit guest-proxy-not-billing label;
- normal CI requires no Boxd credentials;
- final Boxd proof workflow returns to manual-only.
