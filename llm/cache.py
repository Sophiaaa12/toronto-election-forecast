# llm/cache.py
#
# Local disk-based response caching for the OpenRouter pipeline.
#
# Cache key construction (all components folded into one SHA-256):
#   - model ID, provider, model version (if pinned)
#   - temperature, max output tokens, other generation parameters
#   - prompt template version AND the full rendered request content
#     (system + user messages), so any wording change invalidates
#   - candidate ordering mode and order seed (ordering changes the
#     rendered prompt, but is also recorded explicitly)
#   - persona ID, race ID, repeat ID
#
# The cache key therefore uniquely identifies one planned API request.
# Repeated executions of the same planned request reuse its cached
# response (no credits spent). Different repeat IDs hash to different
# keys, so the three repeats of a persona-race pair are three
# INDEPENDENT requests, never copies of one response.
#
# Only successful model answers (valid_choice / undecided / not_voting)
# are cached as successes. Technical failures (missing / invalid /
# timeout / rate_limit / api_error) are written to a separate failures
# area for audit but are never returned as cache hits, so a later run
# retries them.
#
# Each entry stores auditable metadata: request identity, HTTP status,
# timestamps, token usage, and the raw model reply.

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Optional

from .schema import MODEL_STATUSES


@dataclass(frozen=True)
class CacheKey:
    """All fields that jointly identify a planned API request."""

    model_id: str
    provider: str
    model_version: Optional[str]
    temperature: float
    max_tokens: int
    prompt_version: str
    candidate_order: str
    order_seed: Optional[int]
    persona_id: str
    race_id: str
    repeat_id: int
    prompt_sha256: str  # digest of the full rendered messages

    def digest(self) -> str:
        """Stable cryptographic hash (SHA-256) of the canonical request."""
        payload = json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


class ResponseCache:
    """Directory-backed cache: one JSON file per completed request.

    Layout:
        <root>/success/<digest>.json   - cached model answers
        <root>/failures/<digest>.json  - last failure per request (audit)
        <root>/index.jsonl             - append-only audit log of writes
    """

    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.success_dir = self.root / "success"
        self.failure_dir = self.root / "failures"
        self.index_path = self.root / "index.jsonl"

    def _ensure_dirs(self) -> None:
        self.success_dir.mkdir(parents=True, exist_ok=True)
        self.failure_dir.mkdir(parents=True, exist_ok=True)

    def _success_path(self, digest: str) -> Path:
        return self.success_dir / f"{digest}.json"

    def _failure_path(self, digest: str) -> Path:
        return self.failure_dir / f"{digest}.json"

    def get(self, key: CacheKey) -> Optional[dict[str, Any]]:
        """Return the cached SUCCESS entry for this key, else None.

        Failure entries are deliberately never returned here.
        """
        path = self._success_path(key.digest())
        if not path.exists():
            return None
        return json.loads(path.read_text())

    def has(self, key: CacheKey) -> bool:
        return self._success_path(key.digest()).exists()

    def put_success(
        self,
        key: CacheKey,
        response_status: str,
        candidate_id: Optional[str],
        raw_text: str,
        http_status: int,
        usage: Optional[dict[str, Any]],
        model_version_reported: Optional[str] = None,
    ) -> dict[str, Any]:
        """Store a successful model answer and audit its provenance."""
        if response_status not in MODEL_STATUSES:
            raise ValueError(
                "only model answers may be cached as successes; "
                f"got {response_status!r}"
            )
        self._ensure_dirs()
        digest = key.digest()
        entry = {
            "cache_digest": digest,
            "cached_at_unix": time.time(),
            "cached_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "request": asdict(key),
            "result": {
                "response_status": response_status,
                "candidate_id": candidate_id,
            },
            "http_status": http_status,
            "usage": usage or {},
            "model_version_reported": model_version_reported,
            "raw_text": raw_text,
        }
        path = self._success_path(digest)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(entry, indent=2, sort_keys=True))
        tmp.replace(path)  # atomic on POSIX
        self._append_index(digest, "success", response_status)
        return entry

    def put_failure(
        self,
        key: CacheKey,
        response_status: str,
        detail: str,
        raw_text: Optional[str] = None,
        http_status: Optional[int] = None,
    ) -> dict[str, Any]:
        """Record a technical failure for audit.

        Failures are NEVER served as cache hits; they exist so an
        analyst can inspect what went wrong and so the failure rate is
        measurable. A subsequent run re-attempts the request.
        """
        from .schema import FAILURE_STATUSES

        if response_status not in FAILURE_STATUSES:
            raise ValueError(
                f"{response_status!r} is not a technical failure status"
            )
        self._ensure_dirs()
        digest = key.digest()
        entry = {
            "cache_digest": digest,
            "failed_at_unix": time.time(),
            "failed_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "request": asdict(key),
            "result": {"response_status": response_status, "detail": detail},
            "http_status": http_status,
            "raw_text": raw_text,
        }
        path = self._failure_path(digest)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(entry, indent=2, sort_keys=True))
        tmp.replace(path)
        self._append_index(digest, "failure", response_status)
        return entry

    def _append_index(self, digest: str, kind: str, status: str) -> None:
        line = json.dumps(
            {
                "ts_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "digest": digest,
                "kind": kind,
                "response_status": status,
            }
        )
        with self.index_path.open("a") as fh:
            fh.write(line + "\n")

    # -- inspection / invalidation -------------------------------------

    def list_successes(self) -> list[dict[str, Any]]:
        """All cached success entries (for auditing)."""
        if not self.success_dir.exists():
            return []
        out = []
        for p in sorted(self.success_dir.glob("*.json")):
            out.append(json.loads(p.read_text()))
        return out

    def list_failures(self) -> list[dict[str, Any]]:
        if not self.failure_dir.exists():
            return []
        return [json.loads(p.read_text()) for p in sorted(self.failure_dir.glob("*.json"))]

    def stats(self) -> dict[str, int]:
        return {
            "successes": len(list(self.success_dir.glob("*.json")))
            if self.success_dir.exists()
            else 0,
            "failures": len(list(self.failure_dir.glob("*.json")))
            if self.failure_dir.exists()
            else 0,
        }

    def invalidate(
        self,
        digest: Optional[str] = None,
        model_id: Optional[str] = None,
        all_entries: bool = False,
    ) -> int:
        """Remove cached entries. Returns the number removed.

        Three documented ways to invalidate:
          - by exact digest (from the index log or a response row);
          - by model ID (e.g. after changing a model's configuration);
          - everything (all_entries=True).
        Manual invalidation also works: delete files under
        <cache>/success/. This function is a convenience wrapper.
        """
        removed = 0
        if all_entries:
            for p in list(self.success_dir.glob("*.json")) + list(
                self.failure_dir.glob("*.json")
            ):
                p.unlink()
                removed += 1
            return removed
        if digest:
            for p in (self._success_path(digest), self._failure_path(digest)):
                if p.exists():
                    p.unlink()
                    removed += 1
            return removed
        if model_id:
            for kind_dir in (self.success_dir, self.failure_dir):
                if not kind_dir.exists():
                    continue
                for p in list(kind_dir.glob("*.json")):
                    entry = json.loads(p.read_text())
                    if entry.get("request", {}).get("model_id") == model_id:
                        p.unlink()
                        removed += 1
            return removed
        raise ValueError("specify digest, model_id, or all_entries=True")
