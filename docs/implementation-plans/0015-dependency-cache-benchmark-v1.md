# Implementation Plan 0015: Dependency Cache Benchmark v1

## Goal

Measure Dependency Cache v1 with absolute cold/warm bootstrap timings without mixing the result with the earlier Ruby-vs-Go lifecycle benchmark.

The benchmark answers a different question:

~~~text
How much wall-clock bootstrap time is avoided when the executor dependency cache is already populated?
~~~

It does not answer:

~~~text
Is Go faster than Ruby?
~~~

## Method

A benchmark pair runs the same subject twice with the same dependency identity:

~~~text
pair N
  empty executor dependency-cache root
    -> base bootstrap      = cold
    -> candidate bootstrap = warm
~~~

Each new pair receives a fresh dependency-cache root. This prevents pair N+1 from inheriting RunDiff dependency-cache state from pair N.

The runtime, package-manager version, lockfile, OS/architecture, and trust namespace remain unchanged inside each pair.

## Harness

The standalone command is:

~~~bash
go run ./apps/executor-go/cmd/rundiff-cache-benchmark \
  --runtime ruby \
  --root . \
  --tool-root . \
  --pairs 3 \
  --namespace rundiff-hq/rundiff \
  --output tmp/rundiff/dependency-cache-benchmark/ruby.json
~~~

It supports:

~~~text
--runtime auto
--runtime ruby
--runtime node
~~~

For every pair it verifies:

- cold seed is reported as `miss`;
- warm seed is reported as `hit`;
- both runs use the same `RUNDIFF_DEPENDENCY_CACHE_KEY`.

The JSON report records every pair plus median and p95 for cold and warm bootstrap durations.

## CI proof

`.github/workflows/dependency-cache-benchmark.yml` runs the Bundler benchmark on the RunDiff repository itself.

The workflow intentionally does not use `ruby/setup-ruby` dependency caching. The measured cache is the RunDiff executor cache, not a second GitHub/Ruby cache layer.

The first external Node customer fixture will run the same harness in `--runtime node` mode so npm gets an equivalent cold/warm measurement.

## Interpretation

"Cold" means:

~~~text
empty RunDiff dependency-cache root for that pair
~~~

It does not guarantee an empty operating-system page cache, empty CDN cache, or a globally cold package registry.

"Warm" means:

~~~text
the immediately following bootstrap using the same RunDiff dependency-cache identity
~~~

The benchmark therefore supports a cache-effect claim, not a language-performance claim.

## Acceptance

- standalone runtime-neutral cache benchmark command;
- 1-10 independent cold/warm pairs;
- explicit hit/miss and cache-key assertions;
- JSON evidence with absolute timings;
- median and p95 summary;
- automatic Bundler proof on the VS13 PR;
- same command reusable for the external Node fixture.
