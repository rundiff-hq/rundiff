import importlib.util
import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "script" / "provider_economics.py"
DATA_PATH = ROOT / "docs" / "research" / "data" / "provider-economics-v1.json"

spec = importlib.util.spec_from_file_location("provider_economics", MODULE_PATH)
provider_economics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider_economics)


class ProviderEconomicsTest(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(DATA_PATH.read_text(encoding="utf-8"))
        self.report = provider_economics.build_report(self.data)

    def test_github_public_timing_is_not_private_paid_measurement(self):
        github = self.report["github_actions"]
        observed = github["observed_public_runner"]
        private = github["private_standard_runner"]

        self.assertEqual(observed["hardware"]["vcpu"], 4)
        self.assertEqual(observed["hardware"]["ram_gib"], 16)
        self.assertEqual(observed["rounded_minutes"]["median"], 1.0)

        self.assertFalse(private["duration_measured"])
        self.assertEqual(private["hardware"]["vcpu"], 2)
        self.assertEqual(private["hardware"]["ram_gib"], 8)
        self.assertEqual(
            private["paid_cost_sensitivity"]["1"]["usd_per_dispatch"],
            0.006,
        )
        self.assertEqual(
            private["paid_cost_sensitivity"]["2"]["usd_per_dispatch"],
            0.012,
        )

    def test_boxd_execution_cost_envelope_is_deterministic(self):
        boxd = self.report["boxd"]
        self.assertEqual(
            boxd["execution_machine_seconds"]["lower_envelope"],
            7.661,
        )
        self.assertEqual(
            boxd["execution_machine_seconds"]["conservative_envelope"],
            9.315,
        )
        self.assertAlmostEqual(
            boxd["active_compute_eur_per_execution"]["lower_envelope"],
            0.00046817,
            places=8,
        )
        self.assertAlmostEqual(
            boxd["active_compute_eur_per_execution"]["conservative_envelope"],
            0.00056925,
            places=8,
        )

    def test_hibernated_golden_disk_scenarios(self):
        disk = self.report["boxd"][
            "hibernated_golden_disk_eur_per_30_day_month"
        ]
        self.assertEqual(disk["5"], 0.36)
        self.assertEqual(disk["10"], 0.72)
        self.assertEqual(disk["20"], 1.44)

    def test_default_quota_concurrency_is_explicit(self):
        concurrency = self.report["boxd"][
            "default_50_machine_quota_pair_concurrency"
        ]
        self.assertEqual(concurrency["1"], 24)
        self.assertEqual(concurrency["10"], 20)
        self.assertEqual(concurrency["40"], 5)

    def test_scenario_totals_keep_storage_and_compute_separate(self):
        low = self.report["scenarios"]["low_volume"]
        self.assertEqual(low["boxd"]["hot_golden_storage_eur"], 3.6)
        self.assertAlmostEqual(
            low["boxd"]["monthly_total_lower_eur"],
            4.06817222,
            places=8,
        )
        one_minute = low["github_actions_private"][
            "paid_cost_sensitivity"
        ]["1"]
        self.assertEqual(
            one_minute["without_included_minutes_usd"],
            6.0,
        )
        self.assertEqual(
            one_minute["if_all_plan_minutes_available_usd"]["team"],
            0.0,
        )

        high = self.report["scenarios"]["high_volume"]
        self.assertEqual(
            high["boxd"]["default_quota_pair_concurrency"],
            5,
        )
        high_one_minute = high["github_actions_private"][
            "paid_cost_sensitivity"
        ]["1"]
        self.assertEqual(
            high_one_minute["without_included_minutes_usd"],
            600.0,
        )
        self.assertEqual(
            high_one_minute["if_all_plan_minutes_available_usd"][
                "enterprise_cloud"
            ],
            300.0,
        )

    def test_model_does_not_embed_currency_conversion(self):
        self.assertFalse(
            self.report["currencies"]["fx_conversion_embedded"]
        )

    def test_public_github_managed_compute_requires_terms_review(self):
        self.assertEqual(
            self.report["placement_constraints"]["github_public_managed"][
                "status"
            ],
            "terms_review_required",
        )


if __name__ == "__main__":
    unittest.main()
