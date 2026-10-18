# tests/python/test_cost.py
#
# Tests for llm/cost.py: cost log format, actual-vs-estimated separation,
# budget enforcement, and resumable spend accounting.
# No network access; temporary files only.

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from llm.cost import BudgetExceeded, CostTracker, PriceTable  # noqa: E402


def record(tracker, **over):
    base = dict(
        model_id="provider/model-a",
        provider="provider",
        prompt_version="v1",
        persona_id="P000001",
        race_id="mayor",
        repeat_id=1,
        request_status="valid_choice",
        http_status=200,
        usage={"prompt_tokens": 1000, "completion_tokens": 200},
        attempts=1,
        elapsed_seconds=1.5,
    )
    base.update(over)
    return tracker.record(**base)


class TestPriceTable(unittest.TestCase):
    def test_estimate_none_without_prices(self):
        self.assertIsNone(PriceTable().estimate_usd(1000, 200))

    def test_estimate_with_prices(self):
        pt = PriceTable(input_per_mtok=1.0, output_per_mtok=2.0, source="test")
        # 1000 in @ $1/M + 200 out @ $2/M = 0.001 + 0.0004
        self.assertAlmostEqual(pt.estimate_usd(1000, 200), 0.0014, places=8)


class TestCostRecord(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log = Path(self._tmp.name) / "cost_log.jsonl"
        self.tracker = CostTracker(self.log, budget_usd=None)

    def tearDown(self):
        self._tmp.cleanup()

    def test_tokens_recorded(self):
        rec = record(self.tracker)
        self.assertEqual(rec.input_tokens, 1000)
        self.assertEqual(rec.output_tokens, 200)

    def test_reported_cost_wins(self):
        rec = record(
            self.tracker,
            usage={"prompt_tokens": 1000, "completion_tokens": 200, "cost": 0.003},
        )
        self.assertEqual(rec.cost_usd_actual, 0.003)
        self.assertEqual(rec.cost_source, "api_reported")
        self.assertEqual(self.tracker.actual_spent_usd(), 0.003)

    def test_estimate_when_unreported(self):
        tracker = CostTracker(
            self.log,
            prices=PriceTable(input_per_mtok=1.0, output_per_mtok=2.0, source="test"),
        )
        rec = record(tracker)  # usage has no "cost"
        self.assertIsNone(rec.cost_usd_actual)
        self.assertAlmostEqual(rec.cost_usd_estimate, 0.0014, places=8)
        self.assertEqual(rec.cost_source, "estimated")
        # Actual and estimated are reported separately, never merged.
        self.assertEqual(tracker.actual_spent_usd(), 0.0)
        self.assertAlmostEqual(tracker.estimated_spent_usd(), 0.0014, places=8)

    def test_cached_tokens_reported(self):
        rec = record(
            self.tracker,
            usage={
                "prompt_tokens": 1000,
                "completion_tokens": 200,
                "prompt_tokens_details": {"cached_tokens": 800},
            },
        )
        self.assertEqual(rec.cached_tokens_reported, 800)

    def test_log_is_jsonl(self):
        record(self.tracker)
        record(self.tracker, repeat_id=2)
        lines = self.log.read_text().strip().splitlines()
        self.assertEqual(len(lines), 2)
        first = json.loads(lines[0])
        for field in ("model_id", "input_tokens", "output_tokens",
                      "cost_usd_actual", "cost_source", "request_status"):
            self.assertIn(field, first)


class TestBudget(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log = Path(self._tmp.name) / "cost_log.jsonl"

    def tearDown(self):
        self._tmp.cleanup()

    def test_no_budget_always_allows(self):
        tracker = CostTracker(self.log, budget_usd=None)
        record(tracker, usage={"prompt_tokens": 1, "completion_tokens": 1, "cost": 99.0})
        tracker.check_budget()  # must not raise

    def test_blocks_at_budget(self):
        tracker = CostTracker(self.log, budget_usd=0.01)
        record(tracker, usage={"prompt_tokens": 1, "completion_tokens": 1, "cost": 0.02})
        with self.assertRaises(BudgetExceeded):
            tracker.check_budget()
        self.assertFalse(tracker.can_submit())

    def test_allows_below_budget(self):
        tracker = CostTracker(self.log, budget_usd=1.0)
        record(tracker, usage={"prompt_tokens": 1, "completion_tokens": 1, "cost": 0.5})
        tracker.check_budget()
        self.assertTrue(tracker.can_submit())
        self.assertAlmostEqual(tracker.remaining_budget_usd(), 0.5, places=8)

    def test_unreported_costs_use_estimate_conservatively(self):
        tracker = CostTracker(
            self.log,
            budget_usd=0.001,
            prices=PriceTable(input_per_mtok=1.0, output_per_mtok=2.0, source="test"),
        )
        # No reported cost; estimate is 0.0014 > budget 0.001.
        record(tracker, usage={"prompt_tokens": 1000, "completion_tokens": 200})
        self.assertFalse(tracker.can_submit())

    def test_spend_resumes_across_runs(self):
        # First run logs spend; a NEW tracker on the same file must see it
        # (resumable execution respects the budget across runs).
        t1 = CostTracker(self.log, budget_usd=0.5)
        record(t1, usage={"prompt_tokens": 1, "completion_tokens": 1, "cost": 0.4})
        t2 = CostTracker(self.log, budget_usd=0.5)
        self.assertAlmostEqual(t2.actual_spent_usd(), 0.4, places=8)
        # 0.4 already spent; one more $0.15 request pushes total to 0.55
        # which exceeds the $0.50 budget, blocking FURTHER submissions.
        record(t2, usage={"prompt_tokens": 1, "completion_tokens": 1, "cost": 0.15})
        self.assertFalse(t2.can_submit())

    def test_summary_separates_actual_and_estimate(self):
        tracker = CostTracker(
            self.log,
            budget_usd=1.0,
            prices=PriceTable(input_per_mtok=1.0, output_per_mtok=1.0, source="test"),
        )
        record(tracker, usage={"prompt_tokens": 1000, "completion_tokens": 1000, "cost": 0.25})
        s = tracker.summary()
        self.assertEqual(s["actual_reported_usd"], 0.25)
        self.assertAlmostEqual(s["estimated_total_usd"], 0.002, places=8)
        self.assertEqual(s["budget_usd"], 1.0)


if __name__ == "__main__":
    unittest.main()
