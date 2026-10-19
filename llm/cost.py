# llm/cost.py
#
# Cost tracking and budget enforcement for the OpenRouter pipeline.
#
# Principles (per the assignment):
#   - Do NOT assume token prices are fixed. Actual billed cost is taken
#     from the API response when OpenRouter reports it (usage.cost);
#     otherwise it is recorded as unreported and an ESTIMATE based on
#     the analyst-supplied price table is kept separately. Estimated
#     and actual costs are never mixed in one number.
#   - Every submitted request appends one line to a separate cost log
#     (JSONL), independent of the response Parquet, so spend can be
#     audited even if a run is interrupted.
#   - A configurable budget (USD) halts the submission of NEW requests
#     once cumulative actual (or estimated, when unreported) cost would
#     exceed it. In-flight requests finish; the run stops cleanly and
#     reports how far it got.

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any, Optional


@dataclass(frozen=True)
class PriceTable:
    """Analyst-supplied prices (USD per 1M tokens) for ESTIMATES only.

    Prices change; this table is used solely to produce pre-run
    estimates and post-run estimates for responses where OpenRouter did
    not report an actual cost. It is never used to override a reported
    actual cost.
    """

    input_per_mtok: Optional[float] = None   # USD per 1M input tokens
    output_per_mtok: Optional[float] = None  # USD per 1M output tokens
    source: str = "not set"

    def estimate_usd(self, input_tokens: int, output_tokens: int) -> Optional[float]:
        if self.input_per_mtok is None and self.output_per_mtok is None:
            return None
        inp = (input_tokens / 1e6) * (self.input_per_mtok or 0.0)
        out = (output_tokens / 1e6) * (self.output_per_mtok or 0.0)
        return round(inp + out, 8)


@dataclass
class CostRecord:
    """One line in the cost log: one submitted HTTP request."""

    ts_utc: str
    model_id: str
    provider: str
    prompt_version: str
    persona_id: str
    race_id: str
    repeat_id: int
    request_status: str                 # response_status written to Parquet
    http_status: Optional[int]
    input_tokens: Optional[int]         # prompt tokens
    output_tokens: Optional[int]        # completion tokens
    cached_tokens_reported: Optional[int]   # prompt-cache tokens if reported
    cost_usd_actual: Optional[float]    # billed cost as reported by API
    cost_usd_estimate: Optional[float]  # price-table estimate (always filled when possible)
    cost_source: str                    # "api_reported" | "estimated" | "unreported"
    attempts: int
    elapsed_seconds: float


class BudgetExceeded(Exception):
    """Raised when the budget blocks submission of further requests."""

    def __init__(self, message: str, spent_usd: float, budget_usd: float):
        super().__init__(message)
        self.spent_usd = spent_usd
        self.budget_usd = budget_usd


class CostTracker:
    """Append-only JSONL cost log with cumulative budget accounting."""

    def __init__(
        self,
        log_path: str | Path,
        budget_usd: Optional[float] = None,
        prices: Optional[PriceTable] = None,
    ):
        if budget_usd is not None and budget_usd < 0:
            raise ValueError("budget_usd must be >= 0")
        self.log_path = Path(log_path)
        self.budget_usd = budget_usd
        self.prices = prices or PriceTable()
        self._records: list[CostRecord] = []
        self._lock = threading.Lock()
        # Load any prior spend so a resumed run still respects the budget.
        self._load_existing()

    def _load_existing(self) -> None:
        if not self.log_path.exists():
            return
        for line in self.log_path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue  # skip corrupted lines; keep going
            self._records.append(
                CostRecord(
                    ts_utc=d.get("ts_utc", ""),
                    model_id=d.get("model_id", ""),
                    provider=d.get("provider", ""),
                    prompt_version=d.get("prompt_version", ""),
                    persona_id=d.get("persona_id", ""),
                    race_id=d.get("race_id", ""),
                    repeat_id=d.get("repeat_id", -1),
                    request_status=d.get("request_status", ""),
                    http_status=d.get("http_status"),
                    input_tokens=d.get("input_tokens"),
                    output_tokens=d.get("output_tokens"),
                    cached_tokens_reported=d.get("cached_tokens_reported"),
                    cost_usd_actual=d.get("cost_usd_actual"),
                    cost_usd_estimate=d.get("cost_usd_estimate"),
                    cost_source=d.get("cost_source", "unreported"),
                    attempts=d.get("attempts", 0),
                    elapsed_seconds=d.get("elapsed_seconds", 0.0),
                )
            )

    # ------------------------------------------------------------------
    @property
    def records(self) -> list[CostRecord]:
        return list(self._records)

    def actual_spent_usd(self) -> float:
        """Cumulative ACTUAL billed cost (only where reported)."""
        return round(
            sum(r.cost_usd_actual or 0.0 for r in self._records), 8
        )

    def estimated_spent_usd(self) -> float:
        """Cumulative ESTIMATED cost across all logged requests."""
        return round(
            sum(r.cost_usd_estimate or 0.0 for r in self._records), 8
        )

    def unreported_actual_usd(self) -> float:
        """Estimated cost of requests whose actual cost was unreported."""
        return round(
            sum(
                (r.cost_usd_estimate or 0.0)
                for r in self._records
                if r.cost_usd_actual is None
            ),
            8,
        )

    def spent_for_budget(self) -> float:
        """The number the budget is checked against.

        Actual reported cost plus estimates for requests whose actual
        cost the API did not report (conservative: we never under-count
        simply because a price was unreported).
        """
        return round(self.actual_spent_usd() + self.unreported_actual_usd(), 8)

    def remaining_budget_usd(self) -> Optional[float]:
        if self.budget_usd is None:
            return None
        return round(self.budget_usd - self.spent_for_budget(), 8)

    def can_submit(self) -> bool:
        """False when the budget blocks any NEW request."""
        if self.budget_usd is None:
            return True
        return self.spent_for_budget() < self.budget_usd

    def check_budget(self) -> None:
        """Raise BudgetExceeded when no new request may be submitted."""
        if not self.can_submit():
            raise BudgetExceeded(
                f"budget of ${self.budget_usd:.4f} reached "
                f"(spent ${self.spent_for_budget():.4f}); "
                "no further requests will be submitted",
                spent_usd=self.spent_for_budget(),
                budget_usd=self.budget_usd,
            )

    # ------------------------------------------------------------------
    def record(
        self,
        *,
        model_id: str,
        provider: str,
        prompt_version: str,
        persona_id: str,
        race_id: str,
        repeat_id: int,
        request_status: str,
        http_status: Optional[int],
        usage: Optional[dict[str, Any]],
        attempts: int,
        elapsed_seconds: float,
        model_cost_usd: Optional[float] = None,
    ) -> CostRecord:
        """Append one request's cost to the log.

        Token counts come from the API's usage block when present.
        cost_usd_actual prefers the API-reported figure (model_cost_usd
        or usage["cost"]); the estimate from the price table is stored
        alongside and labelled, never merged.
        """
        input_tokens = output_tokens = cached_tokens = None
        if usage:
            input_tokens = usage.get("prompt_tokens")
            output_tokens = usage.get("completion_tokens")
            details = usage.get("prompt_tokens_details") or {}
            cached_tokens = details.get("cached_tokens")
            if cached_tokens is None:
                cached_tokens = usage.get("cached_tokens")

        actual = model_cost_usd
        if actual is None and usage and isinstance(usage.get("cost"), (int, float)):
            actual = float(usage["cost"])

        estimate = None
        if input_tokens is not None and output_tokens is not None:
            estimate = self.prices.estimate_usd(input_tokens, output_tokens)

        if actual is not None:
            source = "api_reported"
        elif estimate is not None:
            source = "estimated"
        else:
            source = "unreported"

        rec = CostRecord(
            ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            model_id=model_id,
            provider=provider,
            prompt_version=prompt_version,
            persona_id=persona_id,
            race_id=race_id,
            repeat_id=repeat_id,
            request_status=request_status,
            http_status=http_status,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cached_tokens_reported=cached_tokens,
            cost_usd_actual=None if actual is None else round(float(actual), 8),
            cost_usd_estimate=estimate,
            cost_source=source,
            attempts=attempts,
            elapsed_seconds=round(elapsed_seconds, 3),
        )
        with self._lock:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a") as fh:
                fh.write(json.dumps(asdict(rec)) + "\n")
            self._records.append(rec)
        return rec

    def summary(self) -> dict[str, Any]:
        """Human-readable spend summary (actual vs estimated kept apart)."""
        return {
            "n_requests_logged": len(self._records),
            "actual_reported_usd": self.actual_spent_usd(),
            "estimated_total_usd": self.estimated_spent_usd(),
            "estimated_on_unreported_usd": self.unreported_actual_usd(),
            "budget_usd": self.budget_usd,
            "spent_for_budget_usd": self.spent_for_budget(),
            "remaining_budget_usd": self.remaining_budget_usd(),
            "price_table_source": self.prices.source,
            "note": (
                "actual_reported_usd is billed cost reported by the API; "
                "estimated_total_usd uses the analyst price table and is "
                "reported separately, never added to actual."
            ),
        }
