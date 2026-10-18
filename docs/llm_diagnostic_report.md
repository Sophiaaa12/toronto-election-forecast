# LLM Diagnostic Experiment — Results Report

**Date:** 2026-10-18 · **Design:** `docs/llm_diagnostic_experiment.md` (preregistered) ·
**Metrics tables:** `processed/diagnostic/metrics_tables.md` ·
**Machine-readable metrics:** `processed/diagnostic/metrics.json` ·
**Analysis script:** `scripts/analyze_llm_diagnostic.py` (read-only; writes only to
`processed/diagnostic/`)

All three approved conditions were executed sequentially with the existing
`llm/models.json` configuration, the original prompt (`prompt_version=v1`,
temperature 0.7, max_tokens 256), the same 12 stratified personas, 2 models, and
3 repeats. No stop condition (§10 of the approval) was triggered.

---

## 1. Execution and cost (actual, API-reported)

| Condition | Order | Planned | HTTP req | Cache hits | Success | Failed | Retries | **Actual billed** |
|---|---|---|---|---|---|---|---|---|
| C0 | ballot (baseline) | 144 | 104 | 40 | 144 | 0 | 0 | **$0.0090367** |
| C1 | random, seed 20261026 | 144 | 144 | 0 | 144 | 0 | 0 | **$0.0124417** |
| C2 | random, seed 7777777 | 144 | 144 | 0 | 144 | 0 | 0 | **$0.0124268** |
| | **Total** | **432** | **392** | **40** | **432** | **0** | **0** | **$0.0339052** |

Cumulative pilot + diagnostic: **$0.0373114 of the $0.05 budget** (remaining
$0.0126886). Every request succeeded on attempt 1 — no errors, timeouts, or rate
limits. Per-condition costs were cross-checked against the cost log slices and the
runner's own final cumulative figure.

**Validity gate: all 7 checks PASS** — 432/432 rows; all personas in the selected 12;
no null candidate IDs on valid answers; every chosen ID is in its race's candidate
list; status vocabulary clean (`valid_choice`, `undecided` only); repeats ∈ {1,2,3};
and the 40 C0 cache-hit rows are **byte-identical to the pilot** (0 mismatches),
confirming the baseline condition exactly reproduces the pilot prompts.

**Pilot artifacts preserved:** pilot `llm_responses.parquet` md5 unchanged
(`d9a387d2…`), pilot cost-log lines byte-identical (`head -40` md5 `56e36bb4…`),
pilot `run_summary.json` restored. Condition outputs live in
`processed/diagnostic/c{0,1,2}_*_responses.parquet` with per-condition summaries
alongside; nothing previously archived was overwritten.

## 2. Headline finding: mayoral degeneracy is **knowledge-driven, not order-driven**

| Diagnostic | Result |
|---|---|
| Unique mayoral choices U | **1** in all 6 (condition × model) cells |
| Winner | **MAYOR-009 in every cell**; top-1 = 1.000 (Wilson lower bounds 0.85–0.90) |
| Entropy H / effective choices | H = 0; exp(H) = 1.00; 1/HHI = 1.00 |
| Cross-condition mayor switch rate | **0.000** in all three condition pairs (160 matched pairs, 0 switches) |
| Winner invariant across all 3 conditions | **49/49 = 1.000** |
| Rank-1 / top-3 capture under shuffles | **0** — the winner is never at the top of shuffled lists |

The decisive evidence: MAYOR-009 was presented at positions **3, 20, 40** (C1) and
**50, 42, 24** of 53 (C2) across the six distinct permutations — including
**position 50/53** — and was chosen **100 % of the time** by both models regardless.
Position bias is ruled out as the mechanism; the models are answering from a stable
prior about the real incumbent mayor, indifferent to persona demographics and to
candidate order.

**Preregistered decision rule applied:** "winner invariant across all three orders →
knowledge-driven degeneracy: report mayoral forecasts as effectively
single-candidate output with a limitation note; no methodology change." This rule
triggered. (The alternative "winner tracks position" rule did not: switch rate 0,
no top-of-list capture.)

## 3. Ward races **are** order-sensitive — the contrast that validates the design

| Metric | Ballot (C0) | Random A (C1) | Random B (C2) |
|---|---|---|---|
| Cross-condition switch rate (ward) | — | 0.288 vs C0 | 0.277 vs C0 / 0.333 vs C1 |
| Winner invariant across all 3 | — | — | 38/64 = 0.594 |
| Repeat agreement, gemini | 0.833 | 0.694 | 0.639 |
| Repeat agreement, gpt-4o-mini | 0.806 | 0.722 | 0.528 |
| Ward mean U (gemini / gpt) | 1.18 / 1.25 | 1.50 / 1.33 | 1.58 / 1.67 |

With 2–4 candidates per ward, reordering moves ~30 % of matched ward choices and
lowers repeat agreement — small lists are genuinely order-sensitive for these models.
Cross-provider ward agreement is only ~0.59–0.63. This is a real measurement
property of ward-level LLM sampling to disclose in the write-up, and it is *not* an
artifact of the pipeline: the same pipeline found zero order sensitivity in the
mayoral race.

## 4. Provider differences: the undecided-rate gap persists

| Condition | gemini-2.5-flash-lite undecided | gpt-4o-mini undecided | Fisher p |
|---|---|---|---|
| C0 | 6/72 = 0.083 [0.039, 0.170] | 15/72 = 0.208 [0.131, 0.316] | 0.057 |
| C1 | 2/72 = 0.028 [0.008, 0.096] | 10/72 = 0.139 [0.077, 0.237] | 0.031 |
| C2 | 0/72 = 0.000 [0.000, 0.051] | 13/72 = 0.181 [0.109, 0.285] | 0.0001 |

gpt-4o-mini returns `undecided` more often than gemini in **all three** conditions
(direction consistent; significant in C2, marginal in C0/C1). Where both models
answer, they agree on the mayoral candidate **100 %** (71/71 matched pairs). Two
providers still provide meaningful independence on the *status* dimension even
though they collapse to the same mayoral choice.

**Preregistered rule applied:** "provider undecided gap persists → keep both
providers, report per-model status rates." Triggered.

## 5. Repeat structure

- **Mayor:** all repeat disagreement is **status flips** (valid ↔ undecided),
  **zero choice flips** in every cell — conditional on answering, the mayoral choice
  is deterministic at temperature 0.7.
- **Ward:** genuine choice flips (4–13 per 36 pairs), rising under shuffled orders;
  agreement rates and Wilson CIs in the metrics tables.

## 6. Demographic sensitivity: none detectable in choices

For the mayoral race, every age group (4) and education group (3) shows U = 1,
top-1 = 1.000, H = 0, and **JSD vs pooled = 0.0000** in all conditions — the
degenerate choice carries zero demographic signal. Ward-race *choices* are not
poolable across wards (different candidate lists), so the comparable statistic is
the undecided rate by group: no consistent pattern for gemini (transient C0 blips
vanish under shuffles); gpt-4o-mini shows small undecided concentrations among
65+ and non-BA personas (e.g. 65+: 1/9, 0/9, 2/9 across C0/C1/C2) — **descriptive
only**; with 3 personas per age cell this is not separable from individual persona
effects, per the design's §6 limitation.

## 7. What this establishes (per preregistered §6)

**Established:** the mayoral degeneracy is a stable, order-invariant,
demographic-invariant prior (both providers, three candidate orders, 432 requests);
the provider undecided gap is real and directionally consistent; ward races are
moderately order-sensitive (~30 % switch rate) with lower cross-provider agreement;
the pipeline, cache, budget enforcement, and provenance all validated end-to-end at
10× pilot scale.

**Not established (unchanged from design §6):** generalization to the 3,042-persona
frame or population vote shares (12 personas, one per cell, persona confounded with
ward); small-effect detection (0/36 upper bound ≈ 8 %); precise entropy estimates;
causal attribution; voter validity. A null demographic result is not evidence of
insensitivity.

## 8. Implications for the production run (methodology unchanged)

1. **Mayoral race:** post-stratified mayoral shares will be degenerate (≈100 % one
   candidate) by construction of model behavior, not by pipeline error. The
   forecast write-up should state this as a measured model limitation. No
   methodology change is made or proposed here.
2. **Ward races:** carry the informative variation; ~30 % order sensitivity and
   ~0.59–0.63 cross-provider agreement should be disclosed as measurement
   properties. Using both providers and 3 repeats (as designed) brackets this
   variability.
3. **Undecided handling:** status rates differ by provider; per-model status rates
   should be reported alongside pooled results.
4. **Scale check:** the full production plan (36,504 requests ≈ $3.11 estimated)
   remains within the validated cost model — the diagnostic's 392 paid calls cost
   $0.0339 actual vs $0.0334 estimated (1.5 % high), confirming the estimate.
5. The production run remains **blocked on separate explicit approval**.

## 9. Constraints honored

No forecasting-methodology change; prompt v1 untouched; pilot artifacts preserved
(md5-verified); per-condition outputs and summaries saved separately; nothing
overwritten; budget respected ($0.0373 of $0.05 cumulative); API key loaded only
from the git-ignored `.env` via `OPENROUTER_API_KEY` and never written to any
output; **nothing committed or pushed**.
