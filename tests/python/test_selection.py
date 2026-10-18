# tests/python/test_selection.py
#
# Tests for reproducible stratified pilot selection
# (llm.runner.select_personas_stratified) and for the unchanged
# default head-N selection.
#
# Requirements under test:
#   - 5 selected personas come from 5 different wards
#   - age and education groups differ across the selection
#   - a fixed seed reproduces the identical selection
#   - a different seed changes the selection
#   - the global random state is never touched
#   - default head-N behaviour is byte-for-byte unchanged
#   - selection changes ONLY which personas are planned (schemas and
#     planning counts are unaffected)
#
# No network access.

import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from llm.prompts import Persona  # noqa: E402
from llm.runner import (  # noqa: E402
    STRATIFIED_SELECTION_SEED,
    load_personas,
    plan_requests,
    select_personas,
    select_personas_stratified,
)

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REAL_PERSONAS = PROJECT_ROOT / "processed" / "simulated" / "simulated_personas.parquet"


def synthetic_personas(n_wards=6, ages=("20-29", "30-44", "45-64", "65+"),
                       edus=("HS", "Postsec", "BA+")):
    """One persona per (ward, age, edu) cell = n_wards * len(ages) * len(edus)."""
    out = []
    pid = 0
    for w in range(1, n_wards + 1):
        for a in ages:
            for e in edus:
                pid += 1
                out.append(Persona(f"P{pid:06d}", w, a, e))
    return out


class TestStratifiedSelection(unittest.TestCase):
    def setUp(self):
        self.personas = synthetic_personas()

    def test_five_personas_from_five_distinct_wards(self):
        sel = select_personas_stratified(self.personas, 5)
        self.assertEqual(len(sel), 5)
        self.assertEqual(len({p.ward for p in sel}), 5)

    def test_age_and_education_groups_are_varied(self):
        sel = select_personas_stratified(self.personas, 5)
        # 5 picks over 4 ages / 3 edus from distinct (age, edu) cells:
        # expect more than one distinct value in each marginal.
        self.assertGreater(len({p.age_group for p in sel}), 1)
        self.assertGreater(len({p.education_group for p in sel}), 1)
        # And the (age, edu) combinations themselves are distinct.
        self.assertEqual(len({(p.age_group, p.education_group) for p in sel}), 5)

    def test_fixed_seed_reproduces_selection(self):
        a = select_personas_stratified(self.personas, 5, seed=42)
        b = select_personas_stratified(self.personas, 5, seed=42)
        self.assertEqual([p.persona_id for p in a], [p.persona_id for p in b])
        # Default seed constant is fixed and documented.
        c = select_personas_stratified(self.personas, 5)
        d = select_personas_stratified(self.personas, 5,
                                       seed=STRATIFIED_SELECTION_SEED)
        self.assertEqual([p.persona_id for p in c], [p.persona_id for p in d])

    def test_different_seed_changes_selection(self):
        a = select_personas_stratified(self.personas, 5, seed=1)
        b = select_personas_stratified(self.personas, 5, seed=2)
        self.assertNotEqual([p.persona_id for p in a], [p.persona_id for p in b])

    def test_global_random_state_untouched(self):
        random.seed(1234)
        state = random.getstate()
        select_personas_stratified(self.personas, 5, seed=7)
        self.assertEqual(random.getstate(), state)

    def test_selection_is_subset_without_duplicates(self):
        sel = select_personas_stratified(self.personas, 10)
        ids = [p.persona_id for p in sel]
        self.assertEqual(len(ids), 10)
        self.assertEqual(len(set(ids)), 10)
        known = {p.persona_id for p in self.personas}
        self.assertTrue(set(ids) <= known)

    def test_more_picks_than_wards_still_unique(self):
        # 6 wards, 10 picks: wards may repeat, personas must not.
        sel = select_personas_stratified(self.personas, 10)
        ids = [p.persona_id for p in sel]
        self.assertEqual(len(set(ids)), 10)
        self.assertEqual(len({p.ward for p in sel}), 6)

    def test_all_personas_when_request_exceeds_available(self):
        sel = select_personas_stratified(self.personas, 10_000)
        self.assertEqual(len(sel), len(self.personas))
        sel_none = select_personas_stratified(self.personas, None)
        self.assertEqual(len(sel_none), len(self.personas))
        # Still deterministic ordering (sorted by ID).
        self.assertEqual([p.persona_id for p in sel],
                         sorted(p.persona_id for p in self.personas))


class TestHeadSelectionUnchanged(unittest.TestCase):
    """The default path must remain byte-identical to prior behaviour."""

    def test_head_is_first_n_sorted(self):
        personas = synthetic_personas()
        head = select_personas(personas, 5)
        self.assertEqual([p.persona_id for p in head],
                         [f"P{i:06d}" for i in range(1, 6)])

    def test_head_none_returns_all(self):
        personas = synthetic_personas()
        self.assertEqual(len(select_personas(personas, None)), len(personas))


class TestSelectionDoesNotChangeMethodology(unittest.TestCase):
    """Selection changes which personas are planned, nothing else."""

    def setUp(self):
        self.crosswalk = load_personas  # placeholder to keep imports tidy
        from llm.runner import load_candidates
        self.cands = load_candidates(
            PROJECT_ROOT / "processed" / "simulated" / "candidate_crosswalk.parquet"
        )
        self.cfg = None
        from llm.config import ModelConfig
        self.cfg = [ModelConfig("prov-a/m", "prov-a", None, 0.7, 256, "v1", 30, 1)]

    @unittest.skipUnless(REAL_PERSONAS.exists(), "simulated personas required")
    def test_request_count_identical_for_any_selection(self):
        personas = load_personas(REAL_PERSONAS)
        head = select_personas(personas, 5)
        strat = select_personas_stratified(personas, 5)
        # Different sets...
        self.assertNotEqual([p.persona_id for p in head],
                            [p.persona_id for p in strat])
        # ...but the planned request count is identical:
        # 5 personas x 2 races x 1 model x 2 repeats.
        n_head = len(plan_requests(head, self.cands, self.cfg,
                                   repeats=2, order_mode="ballot", base_seed=7))
        n_strat = len(plan_requests(strat, self.cands, self.cfg,
                                    repeats=2, order_mode="ballot", base_seed=7))
        self.assertEqual(n_head, n_strat)
        self.assertEqual(n_strat, 5 * 2 * 1 * 2)


@unittest.skipUnless(REAL_PERSONAS.exists(), "simulated personas required")
class TestStratifiedOnRealPersonas(unittest.TestCase):
    """Integration check against the actual 3,042-persona frame."""

    def test_pilot_5_spans_5_wards_and_demographics(self):
        personas = load_personas(REAL_PERSONAS)
        sel = select_personas_stratified(personas, 5)
        self.assertEqual(len(sel), 5)
        self.assertEqual(len({p.ward for p in sel}), 5)
        self.assertGreater(len({p.age_group for p in sel}), 1)
        self.assertGreater(len({p.education_group for p in sel}), 1)

    def test_reproducible_on_real_personas(self):
        personas = load_personas(REAL_PERSONAS)
        a = select_personas_stratified(personas, 5)
        b = select_personas_stratified(personas, 5)
        self.assertEqual([p.persona_id for p in a], [p.persona_id for p in b])


if __name__ == "__main__":
    unittest.main()
