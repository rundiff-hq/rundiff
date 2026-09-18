# Outbound HTTP attribution dogfood

This slice proves that RunDiff can observe a real synchronous outbound network call, attribute it to application code, and project a network-behavior change into GitHub without requiring a manual source marker.

## Controlled regression

The candidate temporarily executes two outbound `Net::HTTP` requests for the `git-comparison` subject while the baseline remains at one.

Expected behavioral result:

```text
functional scenario        pass -> pass
SQL                        unchanged
background jobs            unchanged
emails                     unchanged
outbound HTTP              1 -> 2
runtime source             application Net::HTTP callsite
RunDiff Check                REVIEW / neutral
annotation                 1 warning
```

The generic HTTP count policy is intentionally medium severity. A raw request count does not yet distinguish an idempotent GET from a repeated payment or webhook POST.

## Final acceptance

After the controlled regression is proven, return the candidate to one outbound request while keeping Net::HTTP instrumentation enabled.

Expected final result:

```text
outbound HTTP              1 -> 1
runtime attribution        still present
findings                    []
RunDiff Check                ALLOW / success
annotations                0
```

The loopback endpoint uses a real TCP socket so CI does not depend on external internet availability.
