# llm/schema.py
#
# Strict JSON response validation for the OpenRouter pipeline.
#
# Two SEPARATE status vocabularies, kept distinct per the assignment:
#
#   MODEL ANSWERS (the model produced a usable survey answer):
#     valid_choice, undecided, not_voting
#
#   TECHNICAL FAILURES (no usable model answer was obtained):
#     missing    - API returned no content at all
#     invalid    - response received but unusable (malformed JSON,
#                  missing/extra fields, wrong types, or a candidate_id
#                  that is not in the race's candidate list)
#     timeout    - request timed out after all retries
#     rate_limit - HTTP 429 persisted after all retries
#     api_error  - other HTTP/network/server errors after all retries
#
# A technical failure is NEVER conflated with a model answer, and an
# invalid candidate ID is recorded as "invalid" (not dropped, not
# silently coerced to another status). All rows are retained in the
# output Parquet so downstream accounting can see exactly what happened.
#
# The output field names (response_status, candidate_id) match the
# simulated pipeline so R/simulation_helpers.R can consume the file
# unchanged. The three technical statuses beyond the simulation's
# missing/invalid (timeout, rate_limit, api_error) are supersets of
# "missing/invalid" for estimation purposes: post-stratification uses
# valid_choice rows only.

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Optional

# Statuses the model itself may report.
MODEL_STATUSES = ("valid_choice", "undecided", "not_voting")

# Technical failure statuses produced by the client/validation layer.
FAILURE_STATUSES = ("missing", "invalid", "timeout", "rate_limit", "api_error")

ALL_STATUSES = MODEL_STATUSES + FAILURE_STATUSES

# The strict response schema we ask models to follow.
RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["response_status", "candidate_id"],
    "properties": {
        "response_status": {"enum": list(MODEL_STATUSES)},
        "candidate_id": {
            "oneOf": [{"type": "string"}, {"type": "null"}]
        },
    },
}

# Tolerate (and strip) a ```json ... ``` fence, a common model habit.
_FENCE_RE = re.compile(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", re.DOTALL)


@dataclass(frozen=True)
class ValidationResult:
    response_status: str            # one of ALL_STATUSES
    candidate_id: Optional[str]     # set only for valid_choice
    detail: Optional[str] = None    # human-readable reason for failures


def _strip_fence(text: str) -> str:
    m = _FENCE_RE.match(text)
    return m.group(1) if m else text


def parse_model_json(text: str) -> tuple[Optional[dict], Optional[str]]:
    """Parse the model's reply into a dict, tolerating a code fence.

    Returns (payload, None) on success or (None, reason) on failure.
    Extracts the first {...} block if the model added prose around it,
    but the block itself must be valid JSON.
    """
    if text is None or not text.strip():
        return None, "empty response content"
    cleaned = _strip_fence(text.strip())
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError:
        # Try to locate the outermost JSON object.
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start == -1 or end <= start:
            return None, "no JSON object found in response"
        try:
            payload = json.loads(cleaned[start : end + 1])
        except json.JSONDecodeError as exc:
            return None, f"malformed JSON: {exc}"
    if not isinstance(payload, dict):
        return None, f"expected a JSON object, got {type(payload).__name__}"
    return payload, None


def validate_response(
    text: str,
    allowed_candidate_ids: set[str],
) -> ValidationResult:
    """Validate a raw model reply against the strict schema.

    Checks, in order:
      1. JSON parsing (tolerating a single code fence / surrounding prose);
      2. required fields present (response_status, candidate_id);
      3. response_status is one of the allowed MODEL statuses;
      4. candidate_id type/nullability rules;
      5. for valid_choice: candidate_id is a non-null string that belongs
         to the allowed set for THIS race.
    """
    payload, err = parse_model_json(text)
    if err is not None:
        return ValidationResult("invalid", None, err)

    assert payload is not None
    extra = set(payload) - {"response_status", "candidate_id"}
    if extra:
        return ValidationResult(
            "invalid", None, f"unexpected fields in response: {sorted(extra)}"
        )

    if "response_status" not in payload:
        return ValidationResult("invalid", None, "missing required field: response_status")
    if "candidate_id" not in payload:
        return ValidationResult("invalid", None, "missing required field: candidate_id")

    status = payload["response_status"]
    cid = payload["candidate_id"]

    if not isinstance(status, str) or status not in MODEL_STATUSES:
        return ValidationResult(
            "invalid",
            None,
            f"response_status {status!r} not in {list(MODEL_STATUSES)}",
        )

    if status == "valid_choice":
        if cid is None:
            return ValidationResult(
                "invalid",
                None,
                "valid_choice requires a non-null candidate_id",
            )
        if not isinstance(cid, str):
            return ValidationResult(
                "invalid",
                None,
                f"candidate_id must be a string, got {type(cid).__name__}",
            )
        if cid not in allowed_candidate_ids:
            return ValidationResult(
                "invalid",
                None,
                f"candidate_id {cid!r} is not in this race's candidate list",
            )
        return ValidationResult("valid_choice", cid, None)

    # undecided / not_voting: candidate_id MUST be null.
    if cid is not None:
        return ValidationResult(
            "invalid",
            None,
            f"candidate_id must be null when response_status is {status!r}",
        )
    return ValidationResult(status, None, None)


def failure(status: str, detail: str) -> ValidationResult:
    """Construct a technical-failure result with validation."""
    if status not in FAILURE_STATUSES:
        raise ValueError(f"{status!r} is not a technical failure status")
    return ValidationResult(status, None, detail)
