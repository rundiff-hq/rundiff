#!/usr/bin/env python3
import argparse
import json
import math
import statistics
from pathlib import Path


def money(value):
    return round(value, 8)


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def github_costs(data):
    rate = data["rates"]["github_actions_private_standard_linux"]["per_minute"]
    durations = data["observations"]["github_managed_dispatch_jobs"][
        "job_log_duration_seconds"
    ]
    billed_minutes = [math.ceil(seconds / 60) for seconds in durations]
    per_job = [minutes * rate for minutes in billed_minutes]
    monthly = {}
    for executions in data["model_assumptions"]["monthly_execution_scenarios"]:
        monthly[str(executions)] = money(
            statistics.mean(per_job) * executions
        )

    return {
        "sample_size": len(durations),
        "median_job_seconds": statistics.median(durations),
        "mean_job_seconds": round(statistics.mean(durations), 3),
        "billed_minutes": {
            "median": statistics.median(billed_minutes),
            "mean": round(statistics.mean(billed_minutes), 3),
            "min": min(billed_minutes),
            "max": max(billed_minutes),
        },
        "marginal_paid_cost_usd": {
            "median_per_dispatch": money(statistics.median(per_job)),
            "mean_per_dispatch": money(statistics.mean(per_job)),
            "monthly_by_execution_count": monthly,
        },
        "included_minutes_capacity_if_fully_available": data["rates"][
            "github_actions_private_standard_linux"
        ]["included_minutes_by_plan"],
        "caveats": [
            "Included minutes are shared account entitlements.",
            "Public standard runners are free but commercial-service eligibility is a separate terms constraint.",
            "The model uses observed execute-job duration, not inner executor runtime.",
        ],
    }


def boxd_costs(data):
    assumptions = data["model_assumptions"]
    rate = data["rates"]["boxd"]["default_machine"]["approx_running_hour"]
    disk_rate = data["rates"]["boxd"]["written_disk_gib_hour"]
    machine_seconds = assumptions["boxd_machine_seconds"]

    lower_seconds = (
        machine_seconds["parent_active_per_execution"]
        + 2 * machine_seconds["child_pair_post_fork_ready_each"]
    )
    conservative_seconds = (
        3 * machine_seconds["conservative_all_three_full_wall_each"]
    )

    lower_cost = lower_seconds * rate / 3600
    conservative_cost = conservative_seconds * rate / 3600

    cold = data["observations"]["boxd6"]["cold_lifecycle_ms"]
    cold_seconds = cold["cold_setup"] / 1000
    cleanup_seconds = cold["golden_cleanup"] / 1000

    monthly_execution_costs = {}
    for executions in assumptions["monthly_execution_scenarios"]:
        monthly_execution_costs[str(executions)] = {
            "lower_envelope_eur": money(lower_cost * executions),
            "conservative_envelope_eur": money(
                conservative_cost * executions
            ),
        }

    disk_monthly = {}
    for gib in assumptions["golden_written_disk_gib_scenarios"]:
        disk_monthly[str(gib)] = money(
            gib * disk_rate * assumptions["monthly_hours"]
        )

    quota = data["rates"]["boxd"]["included_machine_quota"]
    concurrency = {}
    for goldens in assumptions["persistent_golden_count_scenarios"]:
        concurrency[str(goldens)] = max(0, (quota - goldens) // 2)

    return {
        "rate_model": "published_default_machine_approx_running_hour",
        "running_rate_eur_per_machine_hour": rate,
        "execution_machine_seconds": {
            "lower_envelope": round(lower_seconds, 3),
            "conservative_envelope": round(conservative_seconds, 3),
        },
        "active_compute_eur_per_execution": {
            "lower_envelope": money(lower_cost),
            "conservative_envelope": money(conservative_cost),
        },
        "cold_golden_eur": {
            "setup": money(cold_seconds * rate / 3600),
            "cleanup": money(cleanup_seconds * rate / 3600),
        },
        "monthly_active_compute_eur": monthly_execution_costs,
        "hibernated_golden_disk_eur_per_30_day_month": disk_monthly,
        "default_50_machine_quota_pair_concurrency": concurrency,
        "caveats": [
            "The published approximately EUR 0.22/hour default-machine rate is used as an upper-envelope simplification.",
            "Boxd bills RAM on actual resident memory, so real active compute may be lower.",
            "The lower envelope excludes unknown child billing during the fork phase.",
            "The conservative envelope bills parent and both children for the full observed Boxd wall time.",
            "Golden disk scenarios are assumptions until actual written disk is measured.",
            "Whether hibernated machines count toward the 50-machine quota should be verified with Boxd before capacity planning.",
        ],
    }


def placement_constraints():
    return {
        "github_public_managed": {
            "status": "terms_review_required",
            "reason": (
                "Do not model free public GitHub Actions as commercial RunDiff "
                "managed compute without explicit terms/legal review."
            ),
        },
        "github_customer_owned_private": {
            "status": "candidate",
            "reason": (
                "Costs and included minutes are charged to the repository owner; "
                "execution remains tied to the customer's software project."
            ),
        },
        "boxd_managed": {
            "status": "candidate",
            "reason": (
                "Supports persistent fork-native state and usage-based billing; "
                "quota, actual RAM and golden storage need production measurement."
            ),
        },
        "boxd_byoc_or_self_host": {
            "status": "enterprise_candidate",
            "reason": (
                "Potential fit for data residency, customer-controlled capacity "
                "and avoiding a central hosted-runner dependency."
            ),
        },
    }


def build_report(data):
    return {
        "schema_version": "1",
        "as_of": data["as_of"],
        "currencies": {
            "boxd": "EUR",
            "github_actions": "USD",
            "fx_conversion_embedded": False,
        },
        "latency_reference": data["observations"]["boxd6"],
        "github_actions": github_costs(data),
        "boxd": boxd_costs(data),
        "placement_constraints": placement_constraints(),
        "decision_rule": (
            "Treat provider choice as constrained placement, not one global "
            "latency or price ranking."
        ),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        default="docs/research/data/provider-economics-v1.json",
    )
    parser.add_argument("--output")
    args = parser.parse_args()

    report = build_report(load(args.input))
    body = json.dumps(report, indent=2) + "\n"
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(body, encoding="utf-8")
    else:
        print(body, end="")


if __name__ == "__main__":
    main()
