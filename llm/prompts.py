# llm/prompts.py
#
# Prompt construction for persona vote-choice queries.
#
# What the LLM receives (documented per the assignment):
#   - the persona's ward number (1-25) for councillor races, or the
#     citywide scope for the mayoral race;
#   - the persona's age group (4 Census bands) and education group
#     (3 Census bands);
#   - the list of candidates for the ONE race being asked about, with
#     their deterministic candidate_id and ballot display name.
#
# What the LLM does NOT receive (deliberate, documented limits):
#   - no sampling weight, cell ID, or other personas (each query is an
#     independent single-persona request);
#   - no policy positions for candidates (we do not invent any);
#   - no fabricated biography beyond the sampled demographic attributes
#     (no names, occupations, histories, or neighbourhoods are added);
#   - no 2022/2023 historical results (no anchoring leakage).
#
# Candidate ordering is configurable and reproducible: orderings are
# "ballot" (default: deterministic crosswalk order = ballot-name sort),
# "random" (seeded per race+model+repeat so it is reproducible), or
# "id". The chosen ordering and its seed are recorded in request
# metadata and folded into the cache key via the rendered prompt text.

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

# Prompt template version. Bumping this invalidates all cached prompts.
PROMPT_VERSION = "v1"

# Candidate-ordering modes accepted by order_candidates().
ORDER_MODES = ("ballot", "random", "id")

# The complete set of instructions sent as the system message. Kept in
# one place so its text is auditable and versioned by PROMPT_VERSION.
SYSTEM_PROMPT = f"""\
You are simulating one Toronto resident answering a short municipal \
election survey for research purposes (prompt version {PROMPT_VERSION}).

You will be told the respondent's ward, age group, and education group, \
and the list of candidates in exactly one race. Reply with ONLY a JSON \
object and no other text, using this exact schema:

{{"response_status": "valid_choice"|"undecided"|"not_voting", \
"candidate_id": "<candidate_id from the list>" or null}}

Rules:
- If response_status is "valid_choice", candidate_id MUST be one of the \
candidate_id values in the provided candidate list (exact string match).
- If response_status is "undecided" or "not_voting", candidate_id MUST \
be null.
- Choose as the described respondent would. Base your choice only on \
the candidate names and the respondent's demographics. Do not invent \
policy positions, biographies, or any information not provided here.
- Do not include markdown, comments, or any text outside the JSON object.
"""

# Daily tracker prompt (v2): same task and JSON schema as v1, plus the
# poll date and a block of that day's Toronto news headlines, which is
# identical for every persona on a given day.
DAILY_PROMPT_VERSION = "v2"

DAILY_SYSTEM_PROMPT_TEMPLATE = """\
You are simulating one Toronto resident answering a short municipal \
election survey for research purposes (prompt version {version}).

Today is {poll_date}. Toronto's municipal election (mayor and ward \
councillors) is on Monday 26 October 2026.

You will be told the respondent's ward, age group, and education group, \
and the list of candidates in exactly one race. Reply with ONLY a JSON \
object and no other text, using this exact schema:

{{"response_status": "valid_choice"|"undecided"|"not_voting", \
"candidate_id": "<candidate_id from the list>" or null}}

Rules:
- If response_status is "valid_choice", candidate_id MUST be one of the \
candidate_id values in the provided candidate list (exact string match).
- If response_status is "undecided" or "not_voting", candidate_id MUST \
be null.
- Choose as the described respondent would, given the candidate names, \
the respondent's demographics, and the local news headlines below, which \
this resident has seen today. Do not invent policy positions, \
biographies, or any information not provided here.
- Do not include markdown, comments, or any text outside the JSON object.

Today's Toronto news headlines ({poll_date}):
{news_block}
"""


@dataclass(frozen=True)
class DailyContext:
    """Per-day context shared by every request in a daily poll."""

    poll_date: str   # YYYY-MM-DD (Toronto time)
    news_block: str  # rendered headlines (llm.news.render_news_block)


def build_daily_system_prompt(context: "DailyContext") -> str:
    return DAILY_SYSTEM_PROMPT_TEMPLATE.format(
        version=DAILY_PROMPT_VERSION,
        poll_date=context.poll_date,
        news_block=context.news_block.strip() or "(no headlines available)",
    )


@dataclass(frozen=True)
class Persona:
    """Minimal persona attributes used for prompting.

    Only the sampled demographic attributes are carried in. The
    sampling weight and cell ID are intentionally NOT part of the
    prompt (they are design metadata, not persona facts).
    """

    persona_id: str
    ward: int
    age_group: str
    education_group: str


@dataclass(frozen=True)
class Candidate:
    candidate_id: str
    display_name: str


def order_candidates(
    candidates: Sequence[Candidate],
    mode: str = "ballot",
    seed: int | None = None,
) -> list[Candidate]:
    """Return candidates in the configured order.

    Modes:
      - "ballot": keep the incoming order (the crosswalk's deterministic
        ballot-name sort). Reproducible with no seed needed.
      - "id": sort by candidate_id.
      - "random": shuffle with an integer seed. The caller passes a seed
        derived from (base_seed, race_id, model_id, repeat_id) so that
        ordering is reproducible across runs yet independent between
        repeats and models.
    """
    if mode not in ORDER_MODES:
        raise ValueError(f"unknown order mode {mode!r}; choose from {ORDER_MODES}")
    if mode == "ballot":
        return list(candidates)
    if mode == "id":
        return sorted(candidates, key=lambda c: c.candidate_id)
    # mode == "random"
    if seed is None:
        raise ValueError("mode='random' requires an integer seed")
    shuffled = list(candidates)
    random.Random(seed).shuffle(shuffled)
    return shuffled


def build_user_prompt(
    persona: Persona,
    race_id: str,
    candidates: Sequence[Candidate],
) -> str:
    """Render the per-request user prompt for one persona x race.

    race_id is "mayor" or "ward_XX_councillor" (the pipeline's existing
    race identifier). The candidate list passed in must already be
    filtered to this race and placed in the configured order.
    """
    if race_id == "mayor":
        scope_line = (
            "Race: Mayor of Toronto (citywide)."
        )
    else:
        ward_num = int(race_id.split("_")[1])
        scope_line = (
            f"Race: City Councillor for Ward {ward_num} "
            f"(you are a resident of Ward {ward_num})."
        )

    cand_lines = "\n".join(
        f"- {c.candidate_id}: {c.display_name}" for c in candidates
    )

    return "\n".join(
        [
            "Respond as the following Toronto resident:",
            f"- Ward: {persona.ward}",
            f"- Age group: {persona.age_group}",
            f"- Education group: {persona.education_group}",
            "",
            scope_line,
            "",
            "Candidates in this race (candidate_id: name):",
            cand_lines,
            "",
            "Return only the JSON object.",
        ]
    )


def build_messages(
    persona: Persona,
    race_id: str,
    candidates: Sequence[Candidate],
    context: DailyContext | None = None,
) -> list[dict[str, str]]:
    """Full chat messages (system + user) for one planned request.

    With a DailyContext the v2 system prompt is used. The news block
    sits in the system message so the long shared prefix is identical
    across all of a day's requests (provider prompt caching).
    """
    system = SYSTEM_PROMPT if context is None else build_daily_system_prompt(context)
    return [
        {"role": "system", "content": system},
        {
            "role": "user",
            "content": build_user_prompt(persona, race_id, candidates),
        },
    ]


def derive_order_seed(
    base_seed: int,
    race_id: str,
    model_id: str,
    repeat_id: int,
) -> int:
    """Deterministic per-request seed for random candidate ordering.

    Uses a stable string hash (not Python's randomized hash()) so the
    ordering is reproducible across processes and machines.
    """
    import hashlib

    material = f"{base_seed}|{race_id}|{model_id}|{repeat_id}"
    digest = hashlib.sha256(material.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def prompt_preview(messages: Iterable[dict[str, str]], max_chars: int = 1200) -> str:
    """Human-readable preview of a prompt for dry-run output."""
    out = []
    for m in messages:
        content = m["content"]
        if len(content) > max_chars:
            content = content[:max_chars] + f"\n... [truncated, {len(m['content'])} chars total]"
        out.append(f"--- {m['role'].upper()} ---\n{content}")
    return "\n".join(out)


def prompt_fingerprint(messages: Sequence[dict[str, str]]) -> dict[str, Any]:
    """Stable digest of the rendered prompt for cache-key/debug use."""
    import hashlib

    joined = "\n".join(f"{m['role']}\n{m['content']}" for m in messages)
    return {
        "sha256": hashlib.sha256(joined.encode("utf-8")).hexdigest(),
        "n_chars": len(joined),
    }
