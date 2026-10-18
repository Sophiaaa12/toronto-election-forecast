# llm/runner.py
#
# CLI orchestrator for the Toronto 2026 LLM sampling pipeline.
#
# Entry point:  python3 -m llm.runner <command> [options]
#
# Commands:
#   run       Plan requests and (unless --dry-run) submit them to
#             OpenRouter, with caching, retries, and budget tracking.
#   cache     Inspect or invalidate cached responses.
#
# The `run` command supports:
#   --dry-run        plan + preview only; no HTTP, no API key needed
#   --max-personas   cap the number of personas selected
#   --max-requests   cap the number of NEW (non-cached) requests
#   --models         comma-separated model IDs to use from the config
#   --repeats        number of independent repeats per persona-race
#   --budget-usd     stop submitting new requests past this spend
#   --config         path to model config JSON
#   --order          candidate ordering mode (ballot|random|id)
#   --seed           base seed for random candidate ordering
#
# Outputs (see Part 9 of the assignment):
#   processed/llm_responses.parquet   schema-compatible with the
#                                     simulated pipeline
#   processed/llm/cost_log.jsonl      separate cost log
#   processed/llm/raw_requests/       raw API responses + metadata
#   processed/llm/run_summary.json    counts, spend, cache statistics
#
# No credentials are written to any output. This module never prints
# the API key.

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, Optional

try:
    import pyarrow as pa
    import pyarrow.parquet as pq
except ImportError:  # pragma: no cover - dependency guard
    print("pyarrow is required: pip install pyarrow", file=sys.stderr)
    raise

from .cache import CacheKey, ResponseCache
from .client import OpenRouterClient
from .config import (
    ConfigError,
    ModelConfig,
    get_api_key,
    load_model_configs,
    require_two_providers,
    require_verified_models,
)
from .cost import BudgetExceeded, CostTracker, PriceTable
from .prompts import (
    PROMPT_VERSION,
    Candidate,
    Persona,
    build_messages,
    derive_order_seed,
    order_candidates,
    prompt_fingerprint,
    prompt_preview,
)
from .schema import MODEL_STATUSES, failure, validate_response

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PERSONAS = PROJECT_ROOT / "processed" / "simulated" / "simulated_personas.parquet"
DEFAULT_CROSSWALK = PROJECT_ROOT / "processed" / "simulated" / "candidate_crosswalk.parquet"
DEFAULT_OUTPUT = PROJECT_ROOT / "processed" / "llm_responses.parquet"
DEFAULT_CACHE_DIR = PROJECT_ROOT / "processed" / "llm_cache"
DEFAULT_COST_LOG = PROJECT_ROOT / "processed" / "llm" / "cost_log.jsonl"
DEFAULT_RAW_DIR = PROJECT_ROOT / "processed" / "llm" / "raw_requests"
DEFAULT_SUMMARY = PROJECT_ROOT / "processed" / "llm" / "run_summary.json"
DEFAULT_CONFIG = PROJECT_ROOT / "llm" / "models.json"
EXAMPLE_CONFIG = PROJECT_ROOT / "llm" / "models.example.json"

SEED_DEFAULT = 20261026  # election day; fixed for reproducible ordering


# ---------------------------------------------------------------------------
# Input loading
# ---------------------------------------------------------------------------

def load_personas(path: Path) -> list[Persona]:
    """Read personas from the simulated pipeline's Parquet output."""
    table = pq.read_table(
        path, columns=["persona_id", "ward", "age_group", "education_group"]
    )
    data = table.to_pydict()
    return [
        Persona(
            persona_id=data["persona_id"][i],
            ward=int(data["ward"][i]),
            age_group=data["age_group"][i],
            education_group=data["education_group"][i],
        )
        for i in range(len(data["persona_id"]))
    ]


def load_candidates(path: Path) -> dict[str, list[Candidate]]:
    """Read the candidate crosswalk, grouped by race_id (ballot order)."""
    table = pq.read_table(
        path, columns=["candidate_id", "race_id", "display_name"]
    )
    data = table.to_pydict()
    by_race: dict[str, list[Candidate]] = {}
    for i in range(len(data["candidate_id"])):
        by_race.setdefault(data["race_id"][i], []).append(
            Candidate(
                candidate_id=data["candidate_id"][i],
                display_name=data["display_name"][i],
            )
        )
    return by_race


# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

def select_personas(
    personas: list[Persona],
    max_personas: Optional[int],
) -> list[Persona]:
    """Deterministic persona selection (sorted by ID, then head-N)."""
    ordered = sorted(personas, key=lambda p: p.persona_id)
    if max_personas is None or max_personas >= len(ordered):
        return ordered
    return ordered[:max_personas]


def plan_requests(
    personas: list[Persona],
    candidates_by_race: dict[str, list[Candidate]],
    configs: list[ModelConfig],
    repeats: int,
    order_mode: str,
    base_seed: int,
) -> list[dict[str, Any]]:
    """Build the full list of planned API requests.

    Each persona answers TWO races: the mayoral race and their own
    ward's councillor race. Each (persona, race, model, repeat) is one
    independent planned request with its own cache key.
    """
    if repeats < 1:
        raise ValueError("repeats must be >= 1")
    plans: list[dict[str, Any]] = []
    for persona in personas:
        ward_race = f"ward_{persona.ward:02d}_councillor"
        for race_id in ("mayor", ward_race):
            base_cands = candidates_by_race.get(race_id)
            if not base_cands:
                raise ConfigError(
                    f"no candidates found for race {race_id!r}; check the "
                    "crosswalk input"
                )
            for cfg in configs:
                for repeat_id in range(1, repeats + 1):
                    seed = (
                        derive_order_seed(base_seed, race_id, cfg.model_id, repeat_id)
                        if order_mode == "random"
                        else None
                    )
                    ordered = order_candidates(base_cands, order_mode, seed)
                    messages = build_messages(persona, race_id, ordered)
                    fp = prompt_fingerprint(messages)
                    key = CacheKey(
                        model_id=cfg.model_id,
                        provider=cfg.provider,
                        model_version=cfg.model_version,
                        temperature=cfg.temperature,
                        max_tokens=cfg.max_tokens,
                        prompt_version=cfg.prompt_version,
                        candidate_order=order_mode,
                        order_seed=seed,
                        persona_id=persona.persona_id,
                        race_id=race_id,
                        repeat_id=repeat_id,
                        prompt_sha256=fp["sha256"],
                    )
                    plans.append(
                        {
                            "key": key,
                            "config": cfg,
                            "persona": persona,
                            "race_id": race_id,
                            "repeat_id": repeat_id,
                            "messages": messages,
                            "allowed_ids": {c.candidate_id for c in ordered},
                            "n_candidates": len(ordered),
                            "prompt_chars": fp["n_chars"],
                        }
                    )
    return plans


# ---------------------------------------------------------------------------
# Output schema (Part 9)
# ---------------------------------------------------------------------------

OUTPUT_COLUMNS = [
    "persona_id", "ward", "race_id", "candidate_id", "provider_id",
    "model_id", "repeat_id", "response_status",
    # audit / provenance columns
    "model_version", "prompt_version", "temperature", "max_tokens",
    "candidate_order", "n_candidates_in_race", "http_status", "attempts",
    "elapsed_seconds", "from_cache", "cache_digest", "request_ts_utc",
    "input_tokens", "output_tokens", "cached_tokens_reported",
    "cost_usd_actual", "cost_usd_estimate", "cost_source", "detail",
]


def write_responses_parquet(rows: list[dict[str, Any]], path: Path) -> None:
    """Write response rows with a fixed, documented schema.

    candidate_id is null for every non-valid_choice status. Types are
    pinned so downstream R code sees stable columns.
    """
    path.parent.mkdir(parents=True, exist_ok=True)

    def col(name: str, typ: pa.DataType) -> pa.Array:
        return pa.array([r.get(name) for r in rows], type=typ)

    schema = pa.schema(
        [
            ("persona_id", pa.string()),
            ("ward", pa.int32()),
            ("race_id", pa.string()),
            ("candidate_id", pa.string()),   # nullable
            ("provider_id", pa.string()),
            ("model_id", pa.string()),
            ("repeat_id", pa.int32()),
            ("response_status", pa.string()),
            ("model_version", pa.string()),
            ("prompt_version", pa.string()),
            ("temperature", pa.float64()),
            ("max_tokens", pa.int32()),
            ("candidate_order", pa.string()),
            ("n_candidates_in_race", pa.int32()),
            ("http_status", pa.int32()),
            ("attempts", pa.int32()),
            ("elapsed_seconds", pa.float64()),
            ("from_cache", pa.bool_()),
            ("cache_digest", pa.string()),
            ("request_ts_utc", pa.string()),
            ("input_tokens", pa.int64()),
            ("output_tokens", pa.int64()),
            ("cached_tokens_reported", pa.int64()),
            ("cost_usd_actual", pa.float64()),
            ("cost_usd_estimate", pa.float64()),
            ("cost_source", pa.string()),
            ("detail", pa.string()),
        ]
    )
    arrays = []
    for field in schema:
        name = field.name
        if name in ("ward", "repeat_id", "temperature", "max_tokens",
                    "n_candidates_in_race", "http_status", "attempts",
                    "elapsed_seconds", "input_tokens", "output_tokens",
                    "cached_tokens_reported", "cost_usd_actual",
                    "cost_usd_estimate"):
            typ = field.type
            vals = []
            for r in rows:
                v = r.get(name)
                vals.append(None if v is None else v)
            arrays.append(pa.array(vals, type=typ))
        else:
            arrays.append(col(name, field.type))
    table = pa.Table.from_arrays(arrays, schema=schema)
    pq.write_table(table, path)


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

def execute_plan(
    plans: list[dict[str, Any]],
    cache: ResponseCache,
    tracker: CostTracker,
    client: Optional[OpenRouterClient],
    raw_dir: Path,
    dry_run: bool,
    max_requests: Optional[int],
    refresh_cache: bool,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Run (or dry-run) a plan. Returns (rows, stats).

    Resumability: cached successes are reused, so re-running a partially
    completed plan only submits the missing requests. Budget checks
    happen BEFORE each new submission.
    """
    rows: list[dict[str, Any]] = []
    stats = {
        "planned": len(plans),
        "from_cache": 0,
        "submitted": 0,
        "succeeded": 0,
        "failed": 0,
        "budget_stopped": False,
        "dry_run": dry_run,
    }
    raw_dir.mkdir(parents=True, exist_ok=True)
    submitted_this_run = 0

    for i, plan in enumerate(plans):
        key: CacheKey = plan["key"]
        cfg: ModelConfig = plan["config"]
        persona: Persona = plan["persona"]

        base_row = {
            "persona_id": persona.persona_id,
            "ward": persona.ward,
            "race_id": plan["race_id"],
            "provider_id": cfg.provider,
            "model_id": cfg.model_id,
            "repeat_id": plan["repeat_id"],
            "model_version": cfg.model_version,
            "prompt_version": cfg.prompt_version,
            "temperature": cfg.temperature,
            "max_tokens": cfg.max_tokens,
            "candidate_order": key.candidate_order,
            "n_candidates_in_race": plan["n_candidates"],
            "cache_digest": key.digest(),
        }

        # ---- cache lookup (skipped with --refresh) ----
        if not refresh_cache:
            hit = cache.get(key)
            if hit is not None:
                stats["from_cache"] += 1
                res = hit["result"]
                rows.append(
                    {
                        **base_row,
                        "candidate_id": res["candidate_id"],
                        "response_status": res["response_status"],
                        "http_status": hit.get("http_status"),
                        "attempts": 0,
                        "elapsed_seconds": 0.0,
                        "from_cache": True,
                        "request_ts_utc": hit.get("cached_at_utc"),
                        "input_tokens": (hit.get("usage") or {}).get("prompt_tokens"),
                        "output_tokens": (hit.get("usage") or {}).get("completion_tokens"),
                        "cached_tokens_reported": ((hit.get("usage") or {}).get("prompt_tokens_details") or {}).get("cached_tokens"),
                        "cost_usd_actual": None,   # already spent earlier
                        "cost_usd_estimate": None,
                        "cost_source": "cache_hit",
                        "detail": "reused cached response (no API call)",
                    }
                )
                continue

        if dry_run:
            rows.append(
                {
                    **base_row,
                    "candidate_id": None,
                    "response_status": "planned",
                    "http_status": None,
                    "attempts": 0,
                    "elapsed_seconds": 0.0,
                    "from_cache": False,
                    "request_ts_utc": None,
                    "input_tokens": None,
                    "output_tokens": None,
                    "cached_tokens_reported": None,
                    "cost_usd_actual": None,
                    "cost_usd_estimate": None,
                    "cost_source": "none",
                    "detail": (
                        f"dry-run: would submit ({plan['n_candidates']} "
                        "candidates in race, prompt "
                        f"{plan['prompt_chars']} chars)"
                    ),
                }
            )
            continue

        # ---- real submission ----
        if max_requests is not None and submitted_this_run >= max_requests:
            stats["max_requests_hit"] = True
            continue

        try:
            tracker.check_budget()
        except BudgetExceeded as exc:
            stats["budget_stopped"] = True
            stats["budget_message"] = str(exc)
            break

        result = client.complete(
            model_id=cfg.model_id,
            messages=plan["messages"],
            temperature=cfg.temperature,
            max_tokens=cfg.max_tokens,
        )
        submitted_this_run += 1
        stats["submitted"] += 1

        ts_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        # Store the raw request/response for audit (never the key).
        raw_path = raw_dir / f"{key.digest()}.json"
        raw_path.write_text(
            json.dumps(
                {
                    "request_ts_utc": ts_utc,
                    "request": asdict(key),
                    "messages": plan["messages"],
                    "generation": {
                        "temperature": cfg.temperature,
                        "max_tokens": cfg.max_tokens,
                    },
                    "http_status": result.http_status,
                    "attempts": result.attempts,
                    "elapsed_seconds": result.elapsed_seconds,
                    "raw_body": result.raw_body,
                    "usage": result.usage,
                    "model_version_reported": result.model_version_reported,
                },
                indent=2,
                sort_keys=True,
            )
        )

        if not result.ok:
            f = failure(
                result.failure_status or "api_error",
                result.detail or "unknown failure",
            )
            cache.put_failure(
                key,
                f.response_status,
                f.detail or "",
                raw_text=result.text,
                http_status=result.http_status,
            )
            tracker.record(
                model_id=cfg.model_id,
                provider=cfg.provider,
                prompt_version=cfg.prompt_version,
                persona_id=persona.persona_id,
                race_id=plan["race_id"],
                repeat_id=plan["repeat_id"],
                request_status=f.response_status,
                http_status=result.http_status,
                usage=result.usage,
                attempts=result.attempts,
                elapsed_seconds=result.elapsed_seconds,
            )
            stats["failed"] += 1
            rows.append(
                {
                    **base_row,
                    "candidate_id": None,
                    "response_status": f.response_status,
                    "http_status": result.http_status,
                    "attempts": result.attempts,
                    "elapsed_seconds": result.elapsed_seconds,
                    "from_cache": False,
                    "request_ts_utc": ts_utc,
                    "input_tokens": (result.usage or {}).get("prompt_tokens"),
                    "output_tokens": (result.usage or {}).get("completion_tokens"),
                    "cached_tokens_reported": ((result.usage or {}).get("prompt_tokens_details") or {}).get("cached_tokens"),
                    "cost_usd_actual": None,
                    "cost_usd_estimate": None,
                    "cost_source": "none",
                    "detail": f.detail,
                }
            )
            continue

        # Successful HTTP round trip: validate the model's answer.
        v = validate_response(result.text, plan["allowed_ids"])
        cost_rec = tracker.record(
            model_id=cfg.model_id,
            provider=cfg.provider,
            prompt_version=cfg.prompt_version,
            persona_id=persona.persona_id,
            race_id=plan["race_id"],
            repeat_id=plan["repeat_id"],
            request_status=v.response_status,
            http_status=result.http_status,
            usage=result.usage,
            attempts=result.attempts,
            elapsed_seconds=result.elapsed_seconds,
        )

        if v.response_status in MODEL_STATUSES:
            cache.put_success(
                key,
                v.response_status,
                v.candidate_id,
                raw_text=result.text,
                http_status=result.http_status,
                usage=result.usage,
                model_version_reported=result.model_version_reported,
            )
            stats["succeeded"] += 1
        else:
            # Validation failed: record as failure, never cache as success.
            cache.put_failure(
                key, v.response_status, v.detail or "",
                raw_text=result.text, http_status=result.http_status,
            )
            stats["failed"] += 1

        rows.append(
            {
                **base_row,
                "candidate_id": v.candidate_id,
                "response_status": v.response_status,
                "http_status": result.http_status,
                "attempts": result.attempts,
                "elapsed_seconds": result.elapsed_seconds,
                "from_cache": False,
                "request_ts_utc": ts_utc,
                "input_tokens": cost_rec.input_tokens,
                "output_tokens": cost_rec.output_tokens,
                "cached_tokens_reported": cost_rec.cached_tokens_reported,
                "cost_usd_actual": cost_rec.cost_usd_actual,
                "cost_usd_estimate": cost_rec.cost_usd_estimate,
                "cost_source": cost_rec.cost_source,
                "detail": v.detail,
            }
        )

    return rows, stats


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python3 -m llm.runner",
        description="Toronto 2026 LLM sampling pipeline (OpenRouter)",
    )
    sub = p.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="plan and (optionally) execute requests")
    run.add_argument("--dry-run", action="store_true",
                     help="plan + preview only; no HTTP, no API key needed")
    run.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                     help="model config JSON (default: llm/models.json)")
    run.add_argument("--personas", type=Path, default=DEFAULT_PERSONAS)
    run.add_argument("--crosswalk", type=Path, default=DEFAULT_CROSSWALK)
    run.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    run.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE_DIR)
    run.add_argument("--max-personas", type=int, default=None)
    run.add_argument("--max-requests", type=int, default=None,
                     help="cap NEW (non-cached) requests this run")
    run.add_argument("--models", type=str, default=None,
                     help="comma-separated model IDs to use from the config")
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--budget-usd", type=float, default=None)
    run.add_argument("--order", choices=["ballot", "random", "id"],
                     default="ballot")
    run.add_argument("--seed", type=int, default=SEED_DEFAULT)
    run.add_argument("--refresh-cache", action="store_true",
                     help="ignore cached responses and re-submit")
    run.add_argument("--preview", type=int, default=2,
                     help="number of prompts to preview in dry-run")
    run.add_argument("--price-input-per-mtok", type=float, default=None,
                     help="USD per 1M input tokens (estimates only)")
    run.add_argument("--price-output-per-mtok", type=float, default=None,
                     help="USD per 1M output tokens (estimates only)")

    cache = sub.add_parser("cache", help="inspect or invalidate the cache")
    cache.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE_DIR)
    cache.add_argument("--list", action="store_true", dest="list_entries")
    cache.add_argument("--list-failures", action="store_true")
    cache.add_argument("--invalidate-model", type=str, default=None)
    cache.add_argument("--invalidate-all", action="store_true")
    return p


def cmd_cache(args: argparse.Namespace) -> int:
    cache = ResponseCache(args.cache_dir)
    if args.invalidate_all:
        n = cache.invalidate(all_entries=True)
        print(f"invalidated {n} cache entries (all)")
        return 0
    if args.invalidate_model:
        n = cache.invalidate(model_id=args.invalidate_model)
        print(f"invalidated {n} cache entries for model {args.invalidate_model}")
        return 0
    stats = cache.stats()
    print(f"cache dir: {args.cache_dir}")
    print(f"successes: {stats['successes']}   failures: {stats['failures']}")
    if args.list_entries:
        for e in cache.list_successes():
            r, res = e["request"], e["result"]
            print(
                f"  {e['cache_digest'][:12]}  {r['persona_id']}  {r['race_id']}  "
                f"{r['model_id']}  rep{r['repeat_id']}  -> {res['response_status']}"
                f"{'/' + res['candidate_id'] if res['candidate_id'] else ''}"
            )
    if args.list_failures:
        for e in cache.list_failures():
            r, res = e["request"], e["result"]
            print(
                f"  {e['cache_digest'][:12]}  {r['persona_id']}  {r['race_id']}  "
                f"{r['model_id']}  rep{r['repeat_id']}  -> {res['response_status']}: "
                f"{res['detail']}"
            )
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    # 1. Model configuration
    config_path = args.config
    if not config_path.exists() and args.config == DEFAULT_CONFIG:
        config_path = EXAMPLE_CONFIG  # fall back to the example for dry runs
    try:
        configs = load_model_configs(config_path)
    except ConfigError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2

    if args.models:
        wanted = {m.strip() for m in args.models.split(",") if m.strip()}
        configs = [c for c in configs if c.model_id in wanted]
        if not configs:
            print(f"--models matched nothing; wanted {sorted(wanted)}",
                  file=sys.stderr)
            return 2

    if len(configs) >= 2:
        try:
            require_two_providers(configs)
        except ConfigError as exc:
            print(f"warning: {exc}", file=sys.stderr)

    if not args.dry_run:
        try:
            require_verified_models(configs)
        except ConfigError as exc:
            print(f"config error: {exc}", file=sys.stderr)
            return 2

    # 2. API key (only needed for real runs)
    try:
        api_key = get_api_key(required=not args.dry_run)
    except ConfigError as exc:
        print(f"key error: {exc}", file=sys.stderr)
        return 2

    # 3. Inputs
    for path in (args.personas, args.crosswalk):
        if not path.exists():
            print(
                f"input not found: {path}\nRun the simulated pipeline first "
                "(Rscript R/run_pipeline.R).",
                file=sys.stderr,
            )
            return 2
    personas = load_personas(args.personas)
    candidates_by_race = load_candidates(args.crosswalk)
    selected = select_personas(personas, args.max_personas)

    # 4. Planning
    plans = plan_requests(
        selected, candidates_by_race, configs,
        repeats=args.repeats, order_mode=args.order, base_seed=args.seed,
    )

    # Candidate-list validation (dry run must catch schema problems).
    races_seen = {p["race_id"] for p in plans}
    for p in plans:
        if p["n_candidates"] < 1:
            print(f"empty candidate list for {p['race_id']}", file=sys.stderr)
            return 2

    # 5. Cost tracking
    prices = PriceTable(
        input_per_mtok=args.price_input_per_mtok,
        output_per_mtok=args.price_output_per_mtok,
        source="cli flags" if (args.price_input_per_mtok or args.price_output_per_mtok) else "not set",
    )
    tracker = CostTracker(DEFAULT_COST_LOG, budget_usd=args.budget_usd, prices=prices)
    cache = ResponseCache(args.cache_dir)

    # 6. Execute (or dry-run)
    client = None
    if not args.dry_run:
        client = OpenRouterClient(
            api_key=api_key,
            timeout_seconds=max(c.timeout_seconds for c in configs),
            max_retries=max(c.max_retries for c in configs),
        )

    print(f"== Toronto 2026 LLM sampling ({'DRY RUN' if args.dry_run else 'LIVE'}) ==")
    print(f"config: {config_path}")
    print(f"models: {', '.join(c.model_id for c in configs)}")
    print(f"personas selected: {len(selected)} of {len(personas)}")
    print(f"repeats per race: {args.repeats}   candidate order: {args.order}")
    print(f"planned requests: {len(plans)} "
          f"({len(selected)} personas x 2 races x {len(configs)} models x {args.repeats} repeats)")
    print(f"races covered: {len(races_seen)}")
    if args.budget_usd is not None:
        print(f"budget: ${args.budget_usd:.4f}")
    print(f"cache: {args.cache_dir} (successes={cache.stats()['successes']})")

    if args.dry_run:
        for plan in plans[: max(0, args.preview)]:
            print("\n" + "=" * 70)
            print(
                f"PLANNED REQUEST  persona={plan['persona'].persona_id} "
                f"race={plan['race_id']} model={plan['config'].model_id} "
                f"repeat={plan['repeat_id']} temp={plan['config'].temperature}"
            )
            print(f"cache_key={plan['key'].digest()}")
            print(prompt_preview(plan["messages"]))
        print("\n(dry run: no HTTP requests were made; no API key required)")

    rows, stats = execute_plan(
        plans, cache, tracker, client,
        raw_dir=DEFAULT_RAW_DIR, dry_run=args.dry_run,
        max_requests=args.max_requests, refresh_cache=args.refresh_cache,
    )

    # 7. Outputs
    if args.dry_run:
        # Dry runs still write a Parquet preview for inspection, with a
        # distinct filename so real outputs are never overwritten.
        preview_path = args.out.with_name("llm_responses_dryrun_preview.parquet")
        write_responses_parquet(rows, preview_path)
        print(f"\ndry-run preview rows: {len(rows)} -> {preview_path}")
    else:
        write_responses_parquet(rows, args.out)
        print(f"\nwrote {len(rows)} response rows -> {args.out}")

    summary = {
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "dry_run": args.dry_run,
        "config_path": str(config_path),
        "models": [c.to_dict() for c in configs],
        "repeats": args.repeats,
        "candidate_order": args.order,
        "seed": args.seed,
        "personas_selected": len(selected),
        "personas_available": len(personas),
        "planned_requests": len(plans),
        "stats": stats,
        "cost": tracker.summary(),
        "cache": cache.stats(),
        "output_path": str(args.out),
    }
    DEFAULT_SUMMARY.parent.mkdir(parents=True, exist_ok=True)
    DEFAULT_SUMMARY.write_text(json.dumps(summary, indent=2, sort_keys=True))
    print(f"run summary -> {DEFAULT_SUMMARY}")
    print("cost summary:", json.dumps(tracker.summary(), indent=2, sort_keys=True))
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    if args.command == "cache":
        return cmd_cache(args)
    if args.command == "run":
        return cmd_run(args)
    parser.error(f"unknown command {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
