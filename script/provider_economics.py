#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path


HOURS_PER_30_DAY_MONTH = 24 * 30
AMORTIZATION_COUNTS = (1, 5, 10, 50)


def ceil_minutes(seconds):
    return int(math.ceil(seconds / 60.0))


def boxd_running_compute_rate_per_hour(rate_card, actual_ram_gib):
    shape = rate_card["default_machine"]
    return (
        shape["vcpu"] * rate_card["vcpu_eur_per_vcpu_hour"]
        + actual_ram_gib * rate_card["ram_eur_per_gib_hour"]
    )


def boxd_execution_cost_eur(config, scenario):
    rate_card = config["rate_cards"]["boxd_cloud"]
    evidence = config["execution_evidence"]["boxd6"]

    compute_rate = boxd_running_compute_rate_per_hour(
        rate_card,
        scenario["boxd_actual_ram_gib_per_running_machine_assumption"],
    )
    steady_hours = evidence["boxd_steady_state_median_ms"] / 3_600_000.0
    child_hours = evidence["boxd_child_active_ms_estimate"] / 3_600_000.0

    golden_compute = compute_rate * steady_hours
    child_compute = 2 * compute_rate * child_hours
    child_disk = (
        2
        * scenario["boxd_child_written_disk_gib_per_execution_assumption"]
        * rate_card["disk_eur_per_gib_hour"]
        * child_hours
    )

    return {
        "golden_compute_eur": golden_compute,
        "children_compute_eur": child_compute,
        "children_disk_eur": child_disk,
        "total_eur": golden_compute + child_compute + child_disk,
    }


def boxd_cold_lifecycle_cost_eur(config, scenario):
    rate_card = config["rate_cards"]["boxd_cloud"]
    evidence = config["execution_evidence"]["boxd6"]
    compute_rate = boxd_running_compute_rate_per_hour(
        rate_card,
        scenario["boxd_actual_ram_gib_per_running_machine_assumption"],
    )
    milliseconds = (
        evidence["boxd_create_golden_ms"]
        + evidence["boxd_prepare_golden_ms"]
        + evidence["boxd_final_cleanup_ms"]
    )
    return compute_rate * milliseconds / 3_600_000.0


def boxd_golden_disk_monthly_eur(config, scenario):
    rate_card = config["rate_cards"]["boxd_cloud"]
    return (
        scenario["retained_goldens"]
        * scenario["boxd_written_disk_gib_per_golden_assumption"]
        * rate_card["disk_eur_per_gib_hour"]
        * HOURS_PER_30_DAY_MONTH
    )


def capacity(config, scenario):
    quota = config["rate_cards"]["boxd_cloud"]["default_machine_quota"]
    retained = scenario["retained_goldens"]
    peak = scenario["peak_concurrent_comparisons"]
    required = retained + (2 * peak)
    available_for_children = max(0, quota - retained)
    max_concurrency = available_for_children // 2
    return {
        "default_machine_quota": quota,
        "retained_goldens": retained,
        "peak_concurrent_comparisons": peak,
        "required_machines_at_peak": required,
        "fits_default_quota": required <= quota,
        "max_concurrent_comparisons_with_retained_goldens": max_concurrency,
        "quota_increase_or_retention_change_required": required > quota,
    }


def github_cost(config, scenario, executions_month):
    rate_card = config["rate_cards"]["github_actions"]
    evidence = config["execution_evidence"]["github_managed_dispatch"]
    billed_minutes = ceil_minutes(evidence["median_job_seconds"])
    nominal = (
        executions_month
        * billed_minutes
        * rate_card["linux_2_core_usd_per_minute"]
    )
    paid_fraction = scenario["github_paid_fraction_assumption"]
    return {
        "median_job_seconds": evidence["median_job_seconds"],
        "billed_minutes_per_execution": billed_minutes,
        "monthly_billable_minutes": executions_month * billed_minutes,
        "nominal_usd_before_included_minutes": nominal,
        "paid_fraction_assumption": paid_fraction,
        "estimated_marginal_paid_usd": nominal * paid_fraction,
        "included_or_customer_allowance_usd_effect": nominal * (1 - paid_fraction),
        "commercial_service_terms_review_required": rate_card[
            "commercial_service_terms_review_required"
        ],
    }


def boxd_cloud_cost(config, scenario, executions_month):
    execution = boxd_execution_cost_eur(config, scenario)
    cold_lifecycle = boxd_cold_lifecycle_cost_eur(config, scenario)
    disk_month = boxd_golden_disk_monthly_eur(config, scenario)

    builds = (
        scenario["retained_goldens"]
        * scenario["golden_builds_per_retained_per_month_assumption"]
    )
    monthly_execution = execution["total_eur"] * executions_month
    monthly_cold = cold_lifecycle * builds

    amortized = {
        str(count): execution["total_eur"] + cold_lifecycle / count
        for count in AMORTIZATION_COUNTS
    }

    return {
        "currency": "EUR",
        "quality": "scenario_estimate_not_measured_invoice",
        "steady_state_execution": execution,
        "cold_lifecycle_eur_per_golden_build": cold_lifecycle,
        "golden_builds_per_month_assumption": builds,
        "golden_disk_eur_per_month": disk_month,
        "steady_state_execution_eur_per_month": monthly_execution,
        "cold_build_compute_eur_per_month": monthly_cold,
        "estimated_total_eur_per_month": (
            disk_month + monthly_execution + monthly_cold
        ),
        "amortized_execution_eur_excluding_monthly_golden_disk": amortized,
    }


def scenario_result(config, scenario):
    executions_month = (
        scenario["repositories"]
        * scenario["executions_per_repo_per_day"]
        * 30
    )
    result = {
        "id": scenario["id"],
        "label": scenario["label"],
        "executions_per_30_day_month": executions_month,
        "inputs": scenario,
        "capacity": capacity(config, scenario),
        "github_actions": github_cost(config, scenario, executions_month),
        "cross_currency_ranking": None,
        "cross_currency_ranking_note": (
            "No EUR/USD conversion is assumed; native-currency costs are "
            "reported separately."
        ),
        "placement_constraints": [
            "GitHub Actions commercial-service terms require review",
            "Queue and control-plane dispatch latency are not modeled",
        ],
    }

    if scenario["boxd_mode"] == "cloud":
        result["boxd"] = boxd_cloud_cost(
            config,
            scenario,
            executions_month,
        )
    else:
        result["boxd"] = {
            "currency": None,
            "quality": "unpriced_custom_byoc",
            "estimated_total_eur_per_month": None,
            "reason": (
                "Boxd BYOC/self-host commercial terms and customer hardware "
                "cost are custom and not publicly priced."
            ),
        }
        result["placement_constraints"].append(
            "BYOC license and underlying customer compute must be priced separately"
        )

    if not result["capacity"]["fits_default_quota"]:
        result["placement_constraints"].append(
            "Default Boxd 50-machine quota is insufficient for this retention/concurrency scenario"
        )

    return result


def build_report(config):
    return {
        "schema_version": "1",
        "checked_at": config["checked_at"],
        "sources": config["sources"],
        "rate_cards": config["rate_cards"],
        "provider_capabilities": config["provider_capabilities"],
        "execution_evidence": config["execution_evidence"],
        "measurement_gaps": config["measurement_gaps"],
        "method": {
            "month_days": 30,
            "boxd_execution_cost": (
                "golden compute for full steady-state + two child compute "
                "for estimated child-active phase + child disk while active"
            ),
            "boxd_retained_golden_disk": (
                "actual-written disk assumption billed for all 720 hours"
            ),
            "github_billing": (
                "ceil observed median execute-job seconds to whole billable minute"
            ),
            "currency_policy": "no implicit EUR/USD conversion",
        },
        "scenarios": [
            scenario_result(config, scenario)
            for scenario in config["scenarios"]
        ],
    }


def money(value, currency):
    if value is None:
        return "unpriced"
    symbol = "€" if currency == "EUR" else "$"
    return f"{symbol}{value:,.2f}"


def build_markdown(report):
    lines = [
        "# Provider Economics v1",
        "",
        f"Rate cards checked: {report['checked_at']}.",
        "",
        "This model keeps EUR and USD separate. It does not choose a provider "
        "by converting currencies implicitly.",
        "",
        "## Evidence",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
        (
            "| BOXD6 steady-state Boxd median | "
            f"{report['execution_evidence']['boxd6']['boxd_steady_state_median_ms']:,} ms |"
        ),
        (
            "| BOXD6 hosted executor median | "
            f"{report['execution_evidence']['boxd6']['hosted_executor_median_ms']:,} ms |"
        ),
        (
            "| GitHub managed execute-job median | "
            f"{report['execution_evidence']['github_managed_dispatch']['median_job_seconds']:.1f} s |"
        ),
        "",
        "## Scenario economics",
        "",
        "| Scenario | Runs/month | Boxd cloud/month | GitHub nominal/month | GitHub paid assumption | Boxd quota |",
        "| --- | ---: | ---: | ---: | ---: | --- |",
    ]

    for scenario in report["scenarios"]:
        boxd = scenario["boxd"]
        github = scenario["github_actions"]
        boxd_cost = money(
            boxd.get("estimated_total_eur_per_month"),
            "EUR",
        )
        github_cost_value = money(
            github["nominal_usd_before_included_minutes"],
            "USD",
        )
        capacity_value = (
            "fits"
            if scenario["capacity"]["fits_default_quota"]
            else "raise/change"
        )
        lines.append(
            "| {label} | {runs:,} | {boxd} | {github} | {paid:.0%} | {quota} |".format(
                label=scenario["label"],
                runs=scenario["executions_per_30_day_month"],
                boxd=boxd_cost,
                github=github_cost_value,
                paid=github["paid_fraction_assumption"],
                quota=capacity_value,
            )
        )

    lines.extend(
        [
            "",
            "## Interpretation boundaries",
            "",
            "- Boxd RAM and disk inputs are scenario assumptions until RunDiff-specific measurements are added.",
            "- GitHub nominal cost is not necessarily the invoice: included minutes can reduce paid marginal cost.",
            "- GitHub Actions commercial-service terms are a placement constraint and require review before treating Actions as RunDiff commercial compute.",
            "- BYOC is intentionally unpriced until Boxd commercial terms and customer infrastructure cost are known.",
            "- Queue latency, control-plane dispatch latency, support/operations cost and FX are not folded into one score.",
            "",
            "## Measurement gaps",
            "",
        ]
    )
    lines.extend(f"- {item}" for item in report["measurement_gaps"])
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="config/provider-economics.v1.json",
    )
    parser.add_argument("--output")
    parser.add_argument("--markdown")
    args = parser.parse_args()

    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    report = build_report(config)

    body = json.dumps(report, indent=2) + "\n"
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(body, encoding="utf-8")
    else:
        print(body, end="")

    if args.markdown:
        markdown = Path(args.markdown)
        markdown.parent.mkdir(parents=True, exist_ok=True)
        markdown.write_text(
            build_markdown(report),
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
