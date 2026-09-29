#!/usr/bin/env python3
import argparse
import json
import math
import statistics
from pathlib import Path


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def summarize(samples, provider):
    values = [item["wall_ms"] for item in samples if item["provider"] == provider]
    return {
        "count": len(values),
        "median_ms": statistics.median(values) if values else 0,
        "p95_ms": percentile(values, 0.95),
        "min_ms": min(values) if values else 0,
        "max_ms": max(values) if values else 0,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    samples = []
    with open(args.samples, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                samples.append(json.loads(line))

    hosted = summarize(samples, "hosted")
    boxd = summarize(samples, "boxd")
    if hosted["count"] != boxd["count"] or hosted["count"] == 0:
        raise SystemExit("hosted and boxd sample counts must match and be non-zero")

    median_ratio = 0
    if boxd["median_ms"]:
        median_ratio = hosted["median_ms"] / boxd["median_ms"]

    paired = []
    pairs = sorted({item["pair"] for item in samples})
    for pair in pairs:
        hosted_item = next(item for item in samples if item["pair"] == pair and item["provider"] == "hosted")
        boxd_item = next(item for item in samples if item["pair"] == pair and item["provider"] == "boxd")
        paired.append({
            "pair": pair,
            "first": "hosted" if hosted_item["sequence_position"] == 1 else "boxd",
            "hosted_ms": hosted_item["wall_ms"],
            "boxd_ms": boxd_item["wall_ms"],
            "hosted_over_boxd_ratio": (
                hosted_item["wall_ms"] / boxd_item["wall_ms"]
                if boxd_item["wall_ms"]
                else 0
            ),
        })

    report = {
        "schema_version": "1",
        "method": {
            "comparison": "executor_runtime_without_provider_queue",
            "pairs": len(pairs),
            "alternating_order": True,
            "fixture": "rundiff-hq/example-node-express-postgres",
            "baseline_sha": "e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb",
            "candidate_sha": "a1663f54380e3a117989ebc6f1ab8f525f6bed4e",
            "expected_outcome": "block",
            "expected_finding": "NEW_RUNTIME_ERROR",
        },
        "summary": {
            "hosted": hosted,
            "boxd": boxd,
            "hosted_over_boxd_median_ratio": round(median_ratio, 3),
        },
        "paired": paired,
        "samples": samples,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
