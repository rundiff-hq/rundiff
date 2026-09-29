#!/usr/bin/env python3
import argparse
import json
import math
import statistics
from pathlib import Path


PREVIOUS_BOXD_MEDIAN_MS = 39738
PREVIOUS_HOSTED_MEDIAN_MS = 2417
BOXD5_BOXD_MEDIAN_MS = 6509
BOXD5_HOSTED_MEDIAN_MS = 2467
AMORTIZATION_COUNTS = (1, 5, 10, 50)


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def summarize_values(values):
    return {
        "count": len(values),
        "median_ms": statistics.median(values) if values else 0,
        "p95_ms": percentile(values, 0.95),
        "min_ms": min(values) if values else 0,
        "max_ms": max(values) if values else 0,
    }


def summarize(samples, provider):
    return summarize_values(
        [item["wall_ms"] for item in samples if item["provider"] == provider]
    )


def summarize_boxd_agent(samples):
    return summarize_values(
        [
            item["agent_total_ms"]
            for item in samples
            if item["provider"] == "boxd" and "agent_total_ms" in item
        ]
    )


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def amortized_boxd(boxd_median_ms, metadata):
    create_ms = metadata["create_golden_ms"]
    prepare_ms = metadata["prepare_golden_ms"]
    cleanup_ms = metadata["golden_cleanup_ms"]
    cold_ms = create_ms + prepare_ms
    result = {}
    for count in AMORTIZATION_COUNTS:
        result[str(count)] = round(
            (cold_ms + cleanup_ms + boxd_median_ms * count) / count,
            3,
        )
    return {
        "create_golden_ms": create_ms,
        "prepare_golden_ms": prepare_ms,
        "cold_setup_ms": cold_ms,
        "golden_cleanup_ms": cleanup_ms,
        "steady_state_median_ms": boxd_median_ms,
        "amortized_median_ms": result,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", required=True)
    parser.add_argument("--boxd-metadata", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    samples = []
    with open(args.samples, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                samples.append(json.loads(line))

    metadata = load_json(args.boxd_metadata)
    hosted = summarize(samples, "hosted")
    boxd = summarize(samples, "boxd")
    boxd_agent = summarize_boxd_agent(samples)
    if hosted["count"] != boxd["count"] or hosted["count"] == 0:
        raise SystemExit(
            "hosted and boxd sample counts must match and be non-zero"
        )

    hosted_over_boxd = 0
    boxd_over_hosted = 0
    if boxd["median_ms"]:
        hosted_over_boxd = hosted["median_ms"] / boxd["median_ms"]
    if hosted["median_ms"]:
        boxd_over_hosted = boxd["median_ms"] / hosted["median_ms"]

    optimized_vs_previous = 0
    optimized_vs_boxd5 = 0
    if boxd["median_ms"]:
        optimized_vs_previous = PREVIOUS_BOXD_MEDIAN_MS / boxd["median_ms"]
        optimized_vs_boxd5 = BOXD5_BOXD_MEDIAN_MS / boxd["median_ms"]

    paired = []
    pairs = sorted({item["pair"] for item in samples})
    for pair in pairs:
        hosted_item = next(
            item
            for item in samples
            if item["pair"] == pair and item["provider"] == "hosted"
        )
        boxd_item = next(
            item
            for item in samples
            if item["pair"] == pair and item["provider"] == "boxd"
        )
        paired.append(
            {
                "pair": pair,
                "first": (
                    "hosted"
                    if hosted_item["sequence_position"] == 1
                    else "boxd"
                ),
                "hosted_ms": hosted_item["wall_ms"],
                "boxd_ms": boxd_item["wall_ms"],
                "boxd_agent_total_ms": boxd_item.get("agent_total_ms"),
                "hosted_over_boxd_ratio": (
                    hosted_item["wall_ms"] / boxd_item["wall_ms"]
                    if boxd_item["wall_ms"]
                    else 0
                ),
            }
        )

    report = {
        "schema_version": "3",
        "method": {
            "comparison": "executor_runtime_without_provider_queue",
            "pairs": len(pairs),
            "alternating_order": True,
            "fixture": "rundiff-hq/example-node-express-postgres",
            "baseline_sha": (
                "e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb"
            ),
            "candidate_sha": (
                "a1663f54380e3a117989ebc6f1ab8f525f6bed4e"
            ),
            "expected_outcome": "block",
            "expected_finding": "NEW_RUNTIME_ERROR",
            "boxd_path": [
                "persistent_prepared_golden",
                "long_lived_pair_sdk",
                "parallel_pair_fork",
                "inherited_running_postgresql",
                "inline_postgresql_verification",
                "parallel_role_capture",
            ],
        },
        "summary": {
            "hosted": hosted,
            "boxd": boxd,
            "boxd_agent_internal": boxd_agent,
            "hosted_over_boxd_median_ratio": round(
                hosted_over_boxd, 3
            ),
            "boxd_over_hosted_median_ratio": round(
                boxd_over_hosted, 3
            ),
            "boxd_minus_hosted_median_ms": (
                boxd["median_ms"] - hosted["median_ms"]
            ),
            "optimized_boxd_vs_v1_speedup": round(
                optimized_vs_previous, 3
            ),
            "collapsed_boxd_vs_boxd5_speedup": round(
                optimized_vs_boxd5, 3
            ),
        },
        "boxd_lifecycle": amortized_boxd(
            boxd["median_ms"],
            metadata,
        ),
        "previous_v1_reference": {
            "run_id": 36587660042,
            "hosted_median_ms": PREVIOUS_HOSTED_MEDIAN_MS,
            "boxd_median_ms": PREVIOUS_BOXD_MEDIAN_MS,
        },
        "boxd5_reference": {
            "run_id": 36645026663,
            "hosted_median_ms": BOXD5_HOSTED_MEDIAN_MS,
            "boxd_median_ms": BOXD5_BOXD_MEDIAN_MS,
        },
        "paired": paired,
        "samples": samples,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
