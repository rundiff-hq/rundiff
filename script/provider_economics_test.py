#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "script" / "provider_economics.py"
SPEC = importlib.util.spec_from_file_location(
    "provider_economics",
    MODULE_PATH,
)
provider_economics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provider_economics)


class ProviderEconomicsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = json.loads(
            (ROOT / "config" / "provider-economics.v1.json").read_text(
                encoding="utf-8"
            )
        )
        cls.report = provider_economics.build_report(cls.config)
        cls.by_id = {
            item["id"]: item
            for item in cls.report["scenarios"]
        }

    def test_github_rounds_each_job_up_to_whole_minute(self):
        self.assertEqual(provider_economics.ceil_minutes(54.7), 1)
        self.assertEqual(provider_economics.ceil_minutes(60.0), 1)
        self.assertEqual(provider_economics.ceil_minutes(60.1), 2)

    def test_low_volume_github_nominal_cost_uses_observed_one_minute_job(self):
        scenario = self.by_id["low_volume_saas"]
        self.assertEqual(
            scenario["executions_per_30_day_month"],
            1500,
        )
        self.assertEqual(
            scenario["github_actions"]["monthly_billable_minutes"],
            1500,
        )
        self.assertAlmostEqual(
            scenario["github_actions"][
                "nominal_usd_before_included_minutes"
            ],
            9.0,
        )

    def test_hibernated_golden_disk_is_charged_for_written_disk(self):
        scenario = self.by_id["low_volume_saas"]
        self.assertAlmostEqual(
            scenario["boxd"]["golden_disk_eur_per_month"],
            14.4,
        )

    def test_boxd_execution_cost_uses_actual_ram_assumption(self):
        low = self.by_id["low_volume_saas"]
        high = self.by_id["high_concurrency_saas"]
        self.assertGreater(
            high["boxd"]["steady_state_execution"]["total_eur"],
            low["boxd"]["steady_state_execution"]["total_eur"],
        )

    def test_default_quota_exposes_retention_concurrency_pressure(self):
        low = self.by_id["low_volume_saas"]
        high = self.by_id["high_concurrency_saas"]
        self.assertTrue(low["capacity"]["fits_default_quota"])
        self.assertFalse(high["capacity"]["fits_default_quota"])
        self.assertEqual(
            high["capacity"]["required_machines_at_peak"],
            300,
        )

    def test_byoc_is_not_priced_from_public_cloud_rate_card(self):
        scenario = self.by_id["customer_byoc"]
        self.assertIsNone(
            scenario["boxd"]["estimated_total_eur_per_month"]
        )
        self.assertEqual(
            scenario["boxd"]["quality"],
            "unpriced_custom_byoc",
        )

    def test_report_never_invents_cross_currency_winner(self):
        for scenario in self.report["scenarios"]:
            self.assertIsNone(scenario["cross_currency_ranking"])

    def test_github_terms_constraint_is_preserved(self):
        for scenario in self.report["scenarios"]:
            self.assertTrue(
                scenario["github_actions"][
                    "commercial_service_terms_review_required"
                ]
            )

    def test_amortized_boxd_cost_declines_with_reuse(self):
        scenario = self.by_id["low_volume_saas"]
        amortized = scenario["boxd"][
            "amortized_execution_eur_excluding_monthly_golden_disk"
        ]
        self.assertGreater(amortized["1"], amortized["5"])
        self.assertGreater(amortized["5"], amortized["10"])
        self.assertGreater(amortized["10"], amortized["50"])


if __name__ == "__main__":
    unittest.main()
