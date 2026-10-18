# tests/python/test_cache.py
#
# Tests for llm/cache.py: cache-key computation, hit/miss behaviour,
# failure non-caching, repeat independence, and invalidation.
# No network access; temporary directories only.

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from llm.cache import CacheKey, ResponseCache  # noqa: E402


def make_key(**overrides) -> CacheKey:
    base = dict(
        model_id="provider/model-a",
        provider="provider",
        model_version=None,
        temperature=0.7,
        max_tokens=256,
        prompt_version="v1",
        candidate_order="ballot",
        order_seed=None,
        persona_id="P000001",
        race_id="mayor",
        repeat_id=1,
        prompt_sha256="a" * 64,
    )
    base.update(overrides)
    return CacheKey(**base)


class TestCacheKey(unittest.TestCase):
    def test_digest_stable(self):
        self.assertEqual(make_key().digest(), make_key().digest())

    def test_every_field_affects_digest(self):
        baseline = make_key().digest()
        variants = [
            dict(model_id="provider/model-b"),
            dict(provider="other"),
            dict(model_version="2026-01-01"),
            dict(temperature=0.9),
            dict(max_tokens=512),
            dict(prompt_version="v2"),
            dict(candidate_order="random"),
            dict(order_seed=99),
            dict(persona_id="P000002"),
            dict(race_id="ward_01_councillor"),
            dict(repeat_id=2),
            dict(prompt_sha256="b" * 64),
        ]
        for v in variants:
            self.assertNotEqual(baseline, make_key(**v).digest(), msg=str(v))

    def test_repeat_ids_are_independent(self):
        # A different repeat ID must be a different planned request,
        # never a copy of the same response.
        r1 = make_key(repeat_id=1).digest()
        r2 = make_key(repeat_id=2).digest()
        r3 = make_key(repeat_id=3).digest()
        self.assertEqual(len({r1, r2, r3}), 3)


class TestResponseCache(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.cache = ResponseCache(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_miss_then_hit(self):
        key = make_key()
        self.assertIsNone(self.cache.get(key))
        self.cache.put_success(
            key, "valid_choice", "MAYOR-001", "raw", 200,
            {"prompt_tokens": 100, "completion_tokens": 20},
        )
        hit = self.cache.get(key)
        self.assertIsNotNone(hit)
        self.assertEqual(hit["result"]["candidate_id"], "MAYOR-001")
        self.assertEqual(hit["request"]["persona_id"], "P000001")
        self.assertEqual(hit["request"]["repeat_id"], 1)

    def test_failures_never_served_as_hits(self):
        key = make_key()
        self.cache.put_failure(key, "timeout", "timed out after retries")
        self.assertIsNone(self.cache.get(key))       # not a hit
        self.assertFalse(self.cache.has(key))
        # But it IS recorded for audit.
        self.assertEqual(len(self.cache.list_failures()), 1)
        self.assertEqual(self.cache.list_failures()[0]["result"]["response_status"],
                         "timeout")

    def test_cannot_cache_failure_as_success(self):
        key = make_key()
        with self.assertRaises(ValueError):
            self.cache.put_success(key, "timeout", None, "", None, None)

    def test_invalid_statuses_rejected(self):
        with self.assertRaises(ValueError):
            self.cache.put_failure(make_key(), "valid_choice", "nope")

    def test_stats_and_invalidate_by_model(self):
        k1 = make_key(persona_id="P000001")
        k2 = make_key(persona_id="P000002", model_id="provider/model-b")
        for k in (k1, k2):
            self.cache.put_success(k, "undecided", None, "raw", 200, None)
        self.assertEqual(self.cache.stats()["successes"], 2)

        removed = self.cache.invalidate(model_id="provider/model-a")
        self.assertEqual(removed, 1)
        self.assertEqual(self.cache.stats()["successes"], 1)
        self.assertTrue(self.cache.has(k2))

    def test_invalidate_all_and_by_digest(self):
        k1 = make_key()
        k2 = make_key(persona_id="P000002")
        for k in (k1, k2):
            self.cache.put_success(k, "not_voting", None, "raw", 200, None)
        self.assertEqual(self.cache.invalidate(digest=k1.digest()), 1)
        self.assertEqual(self.cache.stats()["successes"], 1)
        self.assertEqual(self.cache.invalidate(all_entries=True), 1)
        self.assertEqual(self.cache.stats()["successes"], 0)

    def test_index_log_written(self):
        self.cache.put_success(make_key(), "valid_choice", "MAYOR-001",
                               "raw", 200, None)
        self.assertTrue(self.cache.index_path.exists())
        self.assertIn("success", self.cache.index_path.read_text())


if __name__ == "__main__":
    unittest.main()
