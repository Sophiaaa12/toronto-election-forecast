# tests/python/test_prompts.py
#
# Tests for llm/prompts.py: prompt construction, candidate ordering,
# and reproducibility. No network access.

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from llm.prompts import (  # noqa: E402
    ORDER_MODES,
    Candidate,
    Persona,
    build_messages,
    build_user_prompt,
    derive_order_seed,
    order_candidates,
    prompt_fingerprint,
)

MAYOR_CANDS = [
    Candidate("MAYOR-001", "Imad Abdulkadir"),
    Candidate("MAYOR-002", "Ana Bailao"),
    Candidate("MAYOR-003", "Brad Bradford"),
]
WARD_CANDS = [
    Candidate("W01-C01", "Alice Ng"),
    Candidate("W01-C02", "Bob Chen"),
]
P = Persona("P000001", ward=1, age_group="20-29", education_group="High school or less")


class TestOrdering(unittest.TestCase):
    def test_ballot_is_identity(self):
        self.assertEqual(order_candidates(MAYOR_CANDS, "ballot"), MAYOR_CANDS)

    def test_id_sorts(self):
        got = order_candidates(list(reversed(MAYOR_CANDS)), "id")
        self.assertEqual([c.candidate_id for c in got],
                         ["MAYOR-001", "MAYOR-002", "MAYOR-003"])

    def test_random_reproducible_given_seed(self):
        a = order_candidates(MAYOR_CANDS, "random", seed=42)
        b = order_candidates(MAYOR_CANDS, "random", seed=42)
        self.assertEqual(a, b)

    def test_random_varies_with_seed(self):
        # Use enough candidates that a collision across two fixed seeds is
        # negligible (10! permutations).
        many = [Candidate(f"MAYOR-{i:03d}", f"Candidate {i}") for i in range(1, 11)]
        a = order_candidates(many, "random", seed=1)
        b = order_candidates(many, "random", seed=2)
        self.assertNotEqual(a, b)
        # And each seed covers the same set of candidates (a permutation).
        self.assertEqual(
            sorted(c.candidate_id for c in a),
            sorted(c.candidate_id for c in b),
        )

    def test_random_requires_seed(self):
        with self.assertRaises(ValueError):
            order_candidates(MAYOR_CANDS, "random")

    def test_unknown_mode(self):
        with self.assertRaises(ValueError):
            order_candidates(MAYOR_CANDS, "shuffle")

    def test_derive_order_seed_stable_and_distinct(self):
        s1 = derive_order_seed(7, "mayor", "a/b", 1)
        s1b = derive_order_seed(7, "mayor", "a/b", 1)
        s2 = derive_order_seed(7, "mayor", "a/b", 2)  # different repeat
        s3 = derive_order_seed(7, "mayor", "c/d", 1)  # different model
        self.assertEqual(s1, s1b)
        self.assertNotEqual(s1, s2)
        self.assertNotEqual(s1, s3)


class TestPromptContent(unittest.TestCase):
    def test_uses_demographics_only(self):
        msg = build_user_prompt(P, "mayor", MAYOR_CANDS)
        self.assertIn("Ward: 1", msg)
        self.assertIn("Age group: 20-29", msg)
        self.assertIn("Education group: High school or less", msg)
        # No sampling weight or cell id leaks into the prompt.
        self.assertNotIn("sampling_weight", msg)
        self.assertNotIn("population_cell_id", msg)

    def test_mayor_scope_and_candidates(self):
        msg = build_user_prompt(P, "mayor", MAYOR_CANDS)
        self.assertIn("Mayor of Toronto", msg)
        for c in MAYOR_CANDS:
            self.assertIn(c.candidate_id, msg)
            self.assertIn(c.display_name, msg)

    def test_ward_scope_and_candidates(self):
        msg = build_user_prompt(P, "ward_01_councillor", WARD_CANDS)
        self.assertIn("Ward 1", msg)
        self.assertIn("W01-C01", msg)
        # Ward 2 candidates must not appear in a ward-1 prompt.
        self.assertNotIn("W02-C", msg)

    def test_candidate_order_reflected_in_prompt(self):
        reversed_first = order_candidates(MAYOR_CANDS, "id")
        msg = build_user_prompt(P, "mayor", reversed_first)
        self.assertLess(msg.index("MAYOR-001"), msg.index("MAYOR-003"))

    def test_messages_shape(self):
        msgs = build_messages(P, "mayor", MAYOR_CANDS)
        self.assertEqual(len(msgs), 2)
        self.assertEqual(msgs[0]["role"], "system")
        self.assertEqual(msgs[1]["role"], "user")
        self.assertIn("JSON", msgs[0]["content"])

    def test_prompt_fingerprint_changes_with_content(self):
        fp1 = prompt_fingerprint(build_messages(P, "mayor", MAYOR_CANDS))
        fp2 = prompt_fingerprint(build_messages(P, "mayor", WARD_CANDS))
        self.assertNotEqual(fp1["sha256"], fp2["sha256"])
        self.assertEqual(fp1["sha256"], prompt_fingerprint(build_messages(P, "mayor", MAYOR_CANDS))["sha256"])

    def test_order_modes_covered(self):
        self.assertEqual(set(ORDER_MODES), {"ballot", "random", "id"})


if __name__ == "__main__":
    unittest.main()
