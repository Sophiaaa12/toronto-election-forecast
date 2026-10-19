# tests/python/test_runner.py
#
# Integration tests for llm/runner.py: planning, dry-run behaviour,
# cache reuse, repeat independence, ward-candidate matching, budget
# enforcement, and output Parquet schema.
#
# HTTP is mocked by injecting a scripted OpenRouterClient. These tests
# never contact OpenRouter.

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import pyarrow as pa  # noqa: E402
import pyarrow.parquet as pq  # noqa: E402

from llm.cache import ResponseCache  # noqa: E402
from llm.client import OpenRouterClient  # noqa: E402
from llm.config import (  # noqa: E402
    ConfigError,
    ModelConfig,
    get_api_key,
    load_model_configs,
    require_two_providers,
    require_verified_models,
)
from llm.cost import CostTracker, PriceTable  # noqa: E402
from llm.runner import (  # noqa: E402
    OUTPUT_COLUMNS,
    execute_plan,
    load_candidates,
    load_personas,
    plan_requests,
    select_personas,
    write_responses_parquet,
)

# ---------------------------------------------------------------------------
# Fixtures: a tiny persona + crosswalk set mirroring the real schemas.
# ---------------------------------------------------------------------------

PERSONAS = [
    ("P000001", 1, "20-29", "High school or less"),
    ("P000002", 25, "65+", "Bachelor's degree or higher"),
]
CANDIDATES = [
    ("MAYOR-001", "mayor", "Imad Abdulkadir"),
    ("MAYOR-002", "mayor", "Ana Bailao"),
    ("W01-C01", "ward_01_councillor", "Alice Ng"),
    ("W01-C02", "ward_01_councillor", "Bob Chen"),
    ("W25-C01", "ward_25_councillor", "Zoe Park"),
]


def write_inputs(tmp: Path):
    personas_path = tmp / "personas.parquet"
    pq.write_table(
        pa.table({
            "persona_id": [p[0] for p in PERSONAS],
            "ward": pa.array([p[1] for p in PERSONAS], pa.int32()),
            "age_group": [p[2] for p in PERSONAS],
            "education_group": [p[3] for p in PERSONAS],
        }),
        personas_path,
    )
    crosswalk_path = tmp / "crosswalk.parquet"
    pq.write_table(
        pa.table({
            "candidate_id": [c[0] for c in CANDIDATES],
            "race_id": [c[1] for c in CANDIDATES],
            "display_name": [c[2] for c in CANDIDATES],
        }),
        crosswalk_path,
    )
    return personas_path, crosswalk_path


def make_configs():
    return [
        ModelConfig("provider-a/model", "provider-a", None, 0.7, 256, "v1", 30, 1),
        ModelConfig("provider-b/model", "provider-b", None, 0.7, 256, "v1", 30, 1),
    ]


class FakeHTTP:
    """Scripted responses; each call consumes the next function in `seq`."""

    def __init__(self, seq):
        self.seq = list(seq)
        self.calls = []

    def __call__(self, url, headers=None, data=None, timeout=None):
        payload = json.loads(data)
        self.calls.append(payload)
        idx = min(len(self.calls) - 1, len(self.seq) - 1)
        return self.seq[idx](payload, len(self.calls))


def resp(content):
    def fn(payload, n):
        import json as _json
        class R:
            status_code = 200
            headers = {}
            text = _json.dumps({})
            def json(self):
                return {
                    "choices": [{"message": {"content": content}}],
                    "usage": {"prompt_tokens": 100, "completion_tokens": 20, "cost": 0.0001},
                }
        return R()
    return fn


class TestPlanning(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.personas_path, self.crosswalk_path = write_inputs(self.tmp)

    def tearDown(self):
        self._tmp.cleanup()

    def _plan(self, repeats=3, **kw):
        personas = load_personas(self.personas_path)
        cands = load_candidates(self.crosswalk_path)
        return personas, cands, plan_requests(
            select_personas(personas, kw.get("max_personas")),
            cands, make_configs(), repeats=repeats,
            order_mode=kw.get("order_mode", "ballot"),
            base_seed=kw.get("base_seed", 7),
        )

    def test_two_races_per_persona(self):
        _, _, plans = self._plan(repeats=1)
        races = {(p["persona"].persona_id, p["race_id"]) for p in plans}
        self.assertIn(("P000001", "mayor"), races)
        self.assertIn(("P000001", "ward_01_councillor"), races)
        self.assertIn(("P000002", "ward_25_councillor"), races)

    def test_ward_candidate_matching(self):
        # Ward-1 personas must only see ward-1 candidates (plus all mayors).
        _, _, plans = self._plan(repeats=1)
        for p in plans:
            if p["race_id"] == "ward_01_councillor":
                self.assertEqual(p["allowed_ids"], {"W01-C01", "W01-C02"})
            if p["race_id"] == "ward_25_councillor":
                self.assertEqual(p["allowed_ids"], {"W25-C01"})
            if p["race_id"] == "mayor":
                self.assertEqual(p["allowed_ids"], {"MAYOR-001", "MAYOR-002"})

    def test_request_count_formula(self):
        _, _, plans = self._plan(repeats=3)
        # 2 personas x 2 races x 2 models x 3 repeats
        self.assertEqual(len(plans), 2 * 2 * 2 * 3)

    def test_repeat_ids_independent_keys(self):
        _, _, plans = self._plan(repeats=3)
        mayor_p1 = [p for p in plans
                    if p["persona"].persona_id == "P000001"
                    and p["race_id"] == "mayor"
                    and p["config"].model_id == "provider-a/model"]
        self.assertEqual(len(mayor_p1), 3)
        digests = {p["key"].digest() for p in mayor_p1}
        self.assertEqual(len(digests), 3)  # repeats are 3 distinct requests

    def test_random_order_reproducible(self):
        _, _, a = self._plan(repeats=1, order_mode="random", base_seed=99)
        _, _, b = self._plan(repeats=1, order_mode="random", base_seed=99)
        self.assertEqual(
            [p["key"].digest() for p in a], [p["key"].digest() for p in b]
        )

    def test_max_personas_cap(self):
        personas = select_personas(load_personas(self.personas_path), 1)
        self.assertEqual(len(personas), 1)


class TestConfigGuards(unittest.TestCase):
    def test_example_config_loads_with_placeholders(self):
        example = Path(__file__).resolve().parents[2] / "llm" / "models.example.json"
        configs = load_model_configs(example)
        self.assertEqual(len(configs), 2)
        with self.assertRaises(ConfigError):
            require_verified_models(configs)  # placeholders refused for paid runs

    def test_two_providers_required(self):
        with self.assertRaises(ConfigError):
            require_two_providers(
                [ModelConfig("a/m", "solo", None, 0.7, 256, "v1", 30, 1)]
            )

    def test_env_key_not_required_for_dry(self):
        import os
        os.environ.pop("OPENROUTER_API_KEY", None)
        self.assertIsNone(get_api_key(required=False))
        with self.assertRaises(ConfigError):
            get_api_key(required=True)


class TestExecuteMocked(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.personas_path, self.crosswalk_path = write_inputs(self.tmp)
        self.cache = ResponseCache(self.tmp / "cache")
        self.tracker = CostTracker(
            self.tmp / "cost_log.jsonl",
            budget_usd=None,
            prices=PriceTable(1.0, 2.0, "test"),
        )

    def tearDown(self):
        self._tmp.cleanup()

    def _plans(self, repeats=1, race=None):
        # race: optionally restrict to one race so scripted HTTP replies
        # map 1:1 onto planned requests (each persona plans TWO races).
        personas = load_personas(self.personas_path)
        cands = load_candidates(self.crosswalk_path)
        plans = plan_requests(
            select_personas(personas, 1), cands, make_configs()[:1],
            repeats=repeats, order_mode="ballot", base_seed=7,
        )
        if race is not None:
            plans = [p for p in plans if p["race_id"] == race]
        return plans

    def _client(self, seq):
        http = FakeHTTP(seq)
        return OpenRouterClient(
            api_key="sk-test", max_retries=1, http_post=http,
            sleep=lambda s: None,
        ), http

    def test_valid_choice_row(self):
        client, http = self._client([resp('{"response_status": "valid_choice", "candidate_id": "MAYOR-001"}')])
        rows, stats = execute_plan(
            self._plans(race="mayor"), self.cache, self.tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=None, refresh_cache=False,
        )
        self.assertEqual(stats["succeeded"], len(rows))
        self.assertEqual(rows[0]["response_status"], "valid_choice")
        self.assertEqual(rows[0]["candidate_id"], "MAYOR-001")
        self.assertEqual(rows[0]["input_tokens"], 100)
        self.assertEqual(rows[0]["cost_source"], "api_reported")

    def test_undecided_and_not_voting(self):
        client, _ = self._client([
            resp('{"response_status": "undecided", "candidate_id": null}'),
            resp('{"response_status": "not_voting", "candidate_id": null}'),
        ])
        rows, _ = execute_plan(
            self._plans(repeats=2, race="mayor"), self.cache, self.tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=None, refresh_cache=False,
        )
        self.assertEqual(
            [r["response_status"] for r in rows], ["undecided", "not_voting"]
        )
        self.assertTrue(all(r["candidate_id"] is None for r in rows))

    def test_invalid_candidate_id_recorded_not_cached(self):
        client, _ = self._client([
            resp('{"response_status": "valid_choice", "candidate_id": "MAYOR-999"}'),
        ])
        plans = self._plans(race="mayor")
        rows, stats = execute_plan(
            plans, self.cache, self.tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=None, refresh_cache=False,
        )
        self.assertEqual(rows[0]["response_status"], "invalid")
        self.assertEqual(stats["failed"], 1)
        # Never cached as a success: a rerun re-attempts it.
        self.assertIsNone(self.cache.get(plans[0]["key"]))

    def test_malformed_json_recorded_invalid(self):
        client, _ = self._client([resp("sorry, I cannot decide")])
        rows, _ = execute_plan(
            self._plans(race="mayor"), self.cache, self.tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=None, refresh_cache=False,
        )
        self.assertEqual(rows[0]["response_status"], "invalid")

    def test_429_recorded_rate_limit(self):
        class R429:
            status_code = 429
            headers = {}
            text = "slow down"
            def json(self):
                raise ValueError
        client = OpenRouterClient(
            api_key="sk-test", max_retries=1,
            http_post=lambda *a, **kw: R429(), sleep=lambda s: None,
        )
        rows, _ = execute_plan(
            self._plans(race="mayor"), self.cache, self.tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=None, refresh_cache=False,
        )
        self.assertEqual(rows[0]["response_status"], "rate_limit")
        self.assertIsNone(rows[0]["candidate_id"])

    def test_cache_reuse_on_second_run(self):
        client, http = self._client([resp('{"response_status": "undecided", "candidate_id": null}')])
        plans = self._plans(race="mayor")
        execute_plan(plans, self.cache, self.tracker, client,
                     self.tmp / "raw", False, None, False)
        n_first = len(http.calls)
        rows2, stats2 = execute_plan(plans, self.cache, self.tracker, client,
                                     self.tmp / "raw", False, None, False)
        self.assertEqual(len(http.calls), n_first)  # no new API calls
        self.assertEqual(stats2["from_cache"], len(plans))
        self.assertTrue(all(r["from_cache"] for r in rows2))

    def test_repeats_are_independent_requests(self):
        client, http = self._client(
            [resp('{"response_status": "undecided", "candidate_id": null}')] * 10
        )
        plans = self._plans(repeats=3, race="mayor")
        execute_plan(plans, self.cache, self.tracker, client,
                     self.tmp / "raw", False, None, False)
        self.assertEqual(len(http.calls), 3)  # three separate submissions

    def test_budget_stops_submission(self):
        tracker = CostTracker(self.tmp / "b.jsonl", budget_usd=0.00005)
        client, http = self._client([resp('{"response_status": "undecided", "candidate_id": null}')])
        rows, stats = execute_plan(
            self._plans(repeats=3, race="mayor"), self.cache, tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=None, refresh_cache=False,
        )
        # After the first $0.0001 request, the $0.00005 budget is exceeded.
        self.assertTrue(stats["budget_stopped"])
        self.assertEqual(len(http.calls), 1)

    def test_max_requests_cap(self):
        client, http = self._client([resp('{"response_status": "undecided", "candidate_id": null}')])
        _, stats = execute_plan(
            self._plans(repeats=3, race="mayor"), self.cache, self.tracker, client,
            self.tmp / "raw", dry_run=False, max_requests=2, refresh_cache=False,
        )
        self.assertEqual(len(http.calls), 2)

    def test_dry_run_makes_no_http_calls_and_needs_no_client(self):
        plans = self._plans(repeats=2)
        # client=None is deliberate: a dry run must work without ever
        # constructing an API client (i.e., without an API key).
        rows, stats = execute_plan(
            plans, self.cache, self.tracker, client=None,
            raw_dir=self.tmp / "raw", dry_run=True,
            max_requests=None, refresh_cache=False,
        )
        self.assertEqual(stats["planned"], len(plans))
        self.assertTrue(all(r["response_status"] == "planned" for r in rows))
        self.assertTrue(all(r["candidate_id"] is None for r in rows))

    def test_output_parquet_schema(self):
        rows = [{
            "persona_id": "P000001", "ward": 1, "race_id": "mayor",
            "candidate_id": None, "provider_id": "p", "model_id": "a/m",
            "repeat_id": 1, "response_status": "undecided", "model_version": None,
            "prompt_version": "v1", "temperature": 0.7, "max_tokens": 256,
            "candidate_order": "ballot", "n_candidates_in_race": 2,
            "http_status": 200, "attempts": 1, "elapsed_seconds": 1.0,
            "from_cache": False, "cache_digest": "x" * 64,
            "request_ts_utc": "2026-01-01T00:00:00Z",
            "input_tokens": 100, "output_tokens": 20,
            "cached_tokens_reported": None, "cost_usd_actual": 0.001,
            "cost_usd_estimate": 0.0014, "cost_source": "api_reported",
            "detail": None,
        }]
        out = self.tmp / "out.parquet"
        write_responses_parquet(rows, out)
        tbl = pq.read_table(out)
        self.assertEqual(tbl.schema.names, OUTPUT_COLUMNS)
        # candidate_id must be null for non-valid_choice rows.
        d = tbl.to_pydict()
        self.assertIsNone(d["candidate_id"][0])
        # The simulation pipeline's core columns are present.
        for col in ("persona_id", "ward", "race_id", "candidate_id",
                    "provider_id", "model_id", "repeat_id", "response_status"):
            self.assertIn(col, tbl.schema.names)


if __name__ == "__main__":
    unittest.main()
