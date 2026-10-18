# llm/client.py
#
# OpenRouter chat-completions client with bounded retries.
#
# Failure handling policy (deliberately asymmetric):
#   - Transient failures are retried with exponential backoff + jitter:
#       * HTTP 429 (rate limit)  - honours Retry-After when present;
#       * HTTP 5xx               - transient server errors;
#       * network timeouts and connection errors.
#   - Permanent failures are NOT retried:
#       * HTTP 400/401/403/404/422 - the request itself is invalid
#         (bad payload, bad key, unknown model); retrying cannot help;
#       * HTTP 402                 - insufficient credits (budget-side).
#   - Each model config carries max_retries and timeout_seconds; retries
#     stop at max_retries and the failure is recorded as timeout /
#     rate_limit / api_error rather than looping forever.
#
# The client never logs or stores the API key. It returns a structured
# ClientResult that the caller validates and caches; raw HTTP bodies
# are returned verbatim for audit storage.

from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

import requests

# OpenRouter endpoint (chat completions, OpenAI-compatible).
OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"

# HTTP status classes.
RETRYABLE_STATUS = {429, 500, 502, 503, 504}
PERMANENT_STATUS = {400, 401, 402, 403, 404, 422}


class APIError(Exception):
    """A request failed permanently (after any retries)."""

    def __init__(self, message: str, status: Optional[int] = None):
        super().__init__(message)
        self.status = status


@dataclass
class ClientResult:
    """Outcome of one HTTP attempt chain for one planned request."""

    ok: bool                          # a body came back with HTTP 200
    http_status: Optional[int]        # final HTTP status, if any
    text: Optional[str]               # raw assistant content (if parseable)
    usage: Optional[dict[str, Any]]   # token usage as reported
    model_version_reported: Optional[str]
    failure_status: Optional[str]     # missing/timeout/rate_limit/api_error
    detail: Optional[str] = None
    attempts: int = 0
    elapsed_seconds: float = 0.0
    raw_body: Optional[str] = None    # full JSON body for audit storage
    extras: dict[str, Any] = field(default_factory=dict)


def _parse_retry_after(resp: requests.Response) -> Optional[float]:
    ra = resp.headers.get("Retry-After")
    if ra is None:
        return None
    try:
        return max(0.0, float(ra))
    except ValueError:
        return None  # HTTP-date form: ignore, fall back to backoff


def _extract_content(body: dict[str, Any]) -> tuple[Optional[str], Optional[dict]]:
    """Pull assistant text and usage out of an OpenAI-style body."""
    usage = body.get("usage") or None
    choices = body.get("choices") or []
    if not choices:
        return None, usage
    message = choices[0].get("message") or {}
    content = message.get("content")
    return (content if isinstance(content, str) else None), usage


class OpenRouterClient:
    """Minimal, auditable OpenRouter client.

    `http_post` is injectable so tests can mock HTTP without any
    network access (the assignment requires mocked tests).
    """

    def __init__(
        self,
        api_key: Optional[str],
        timeout_seconds: float = 60.0,
        max_retries: int = 5,
        backoff_base_seconds: float = 1.0,
        backoff_cap_seconds: float = 60.0,
        user_agent: str = "sta2453-toronto-forecast/0.1",
        http_post: Optional[Callable[..., requests.Response]] = None,
        sleep: Callable[[float], None] = time.sleep,
        rng: Optional[random.Random] = None,
    ):
        if not api_key:
            raise APIError(
                "OpenRouterClient requires an API key; dry runs must not "
                "construct a client"
            )
        self._api_key = api_key
        self.timeout_seconds = timeout_seconds
        self.max_retries = max_retries
        self.backoff_base = backoff_base_seconds
        self.backoff_cap = backoff_cap_seconds
        self.user_agent = user_agent
        self._http_post = http_post or requests.post
        self._sleep = sleep
        self._rng = rng or random.Random()

    # ------------------------------------------------------------------
    def _backoff(self, attempt: int, retry_after: Optional[float]) -> float:
        """Exponential backoff with jitter, capped; Retry-After wins."""
        if retry_after is not None:
            return min(retry_after, self.backoff_cap)
        delay = min(self.backoff_base * (2 ** attempt), self.backoff_cap)
        jitter = self._rng.uniform(0, delay * 0.25)
        return delay + jitter

    def complete(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        temperature: float,
        max_tokens: int,
    ) -> ClientResult:
        """Issue one chat-completions request with bounded retries."""
        payload = {
            "model": model_id,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            # Ask OpenRouter for token usage in the response.
            "usage": {"include": True},
        }
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/Sophiaaa12/toronto-election-forecast",
            "X-Title": "STA2453 Toronto 2026 Election Forecast",
            "User-Agent": self.user_agent,
        }

        started = time.time()
        attempts = 0
        last_failure = ("api_error", "request was never attempted")
        last_http: Optional[int] = None

        while attempts <= self.max_retries:
            attempts += 1
            retry_after: Optional[float] = None
            try:
                resp = self._http_post(
                    OPENROUTER_API_URL,
                    headers=headers,
                    data=json.dumps(payload),
                    timeout=self.timeout_seconds,
                )
            except requests.Timeout as exc:
                last_failure = ("timeout", f"timed out: {exc}")
                last_http = None
            except requests.RequestException as exc:
                last_failure = ("api_error", f"network error: {exc}")
                last_http = None
            else:
                last_http = resp.status_code
                if resp.status_code == 200:
                    raw_body = resp.text
                    try:
                        body = resp.json()
                    except ValueError:
                        last_failure = ("invalid", "200 but body is not JSON")
                        break  # a 200 with a non-JSON body will not improve on retry
                    content, usage = _extract_content(body)
                    if content is None or not content.strip():
                        # Well-formed HTTP, but no assistant text: record as
                        # missing (a technical failure, not a model answer).
                        return ClientResult(
                            ok=False,
                            http_status=200,
                            text=None,
                            usage=usage,
                            model_version_reported=body.get("model_version"),
                            failure_status="missing",
                            detail="response contained no assistant content",
                            attempts=attempts,
                            elapsed_seconds=time.time() - started,
                            raw_body=raw_body,
                        )
                    return ClientResult(
                        ok=True,
                        http_status=200,
                        text=content,
                        usage=usage,
                        model_version_reported=body.get("model_version"),
                        failure_status=None,
                        attempts=attempts,
                        elapsed_seconds=time.time() - started,
                        raw_body=raw_body,
                    )

                if resp.status_code in RETRYABLE_STATUS:
                    retry_after = _parse_retry_after(resp)
                    if resp.status_code == 429:
                        last_failure = (
                            "rate_limit",
                            f"HTTP 429 after {attempts} attempt(s)",
                        )
                    else:
                        last_failure = (
                            "api_error",
                            f"HTTP {resp.status_code} after {attempts} attempt(s)",
                        )
                elif resp.status_code in PERMANENT_STATUS:
                    # Do not retry permanently invalid requests.
                    return ClientResult(
                        ok=False,
                        http_status=resp.status_code,
                        text=None,
                        usage=None,
                        model_version_reported=None,
                        failure_status="api_error",
                        detail=(
                            f"HTTP {resp.status_code} (permanent, not retried): "
                            f"{resp.text[:300]}"
                        ),
                        attempts=attempts,
                        elapsed_seconds=time.time() - started,
                        raw_body=resp.text[:2000],
                    )
                else:
                    return ClientResult(
                        ok=False,
                        http_status=resp.status_code,
                        text=None,
                        usage=None,
                        model_version_reported=None,
                        failure_status="api_error",
                        detail=(
                            f"unexpected HTTP {resp.status_code}: {resp.text[:300]}"
                        ),
                        attempts=attempts,
                        elapsed_seconds=time.time() - started,
                        raw_body=resp.text[:2000],
                    )

            # Retryable path (timeout / network / 429 / 5xx).
            if attempts > self.max_retries:
                break
            self._sleep(self._backoff(attempts - 1, retry_after))

        status, detail = last_failure
        return ClientResult(
            ok=False,
            http_status=last_http,
            text=None,
            usage=None,
            model_version_reported=None,
            failure_status=status,
            detail=f"{detail} (gave up after {attempts} attempt(s))",
            attempts=attempts,
            elapsed_seconds=time.time() - started,
        )
