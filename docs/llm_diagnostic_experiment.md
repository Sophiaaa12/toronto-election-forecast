# LLM Pilot Diagnostic Experiment — Design (pre-registered, no API calls made)

**Status:** design + dry-run verification only. No paid API requests were made for this
experiment. The statistical forecasting pipeline is unchanged. The 40 pilot responses in
`processed/llm_responses.parquet` are untouched (md5 `d9a387d2a78dccbfbf07c2730c75835c`
before and after; cost log md5 `56e36bb46e622fb060038e73872018a6`, still 40 entries).

**Motivation (pilot findings to diagnose):** (a) mayoral responses are degenerate — both
models chose MAYOR-009 (Olivia Chow) 17/17 valid answers, 1 unique choice; (b) undecided
rates differ by provider (gpt-4o-mini 15 % vs gemini-2.5-flash-lite 0 %); (c) ward races
spread over 6–7 candidates, so the degeneracy is race-specific, not a general collapse.

---

## 1. What the pilot already showed (inspection of responses and prompts)

| Item | Observation |
|---|---|
| Format validity | 100 % valid JSON, 100 % valid candidate IDs (40/40) |
| Mayor diversity | U = 1 unique choice (MAYOR-009) across both models, both repeats |
| Ward diversity | 6–7 unique choices per ward race |
| Undecided | gpt-4o-mini 3/20; gemini 0/20; `not_voting` 0/40 |
| Repeats | 85 % pairwise agreement (17 agree / 3 differ) — repeats are not identical |
| Tokens (measured) | mayor ~816–924 in / 15–26 out; ward ~309–409 in / 15–33 out |
| Billed cost | $0.0034062 actual (API-reported), 0 failures, 0 retries |
| Prompt | `prompt_version=v1`, `temperature=0.7`, `max_tokens=256`, `candidate_order=ballot` |

A key structural fact for diagnosis: the crosswalk's stored order **already equals**
`candidate_id` order **and** `ballot_name` sort order for all 26 races. Therefore
`--order id` renders byte-identical prompts to `--order ballot` (verified: 0/26 races
differ). **`--order id` is excluded from the design** — it would pay full price for
duplicate prompts and add no information. Order sensitivity must come from `--order random`.

## 2. Balanced diagnostic sample

**12 personas, full factorial, one per cell** (via the existing reproducible stratified
selection; `--selection stratified --selection-seed 20261026 --max-personas 12`):

- **Age groups:** 4/4 covered (20-29, 30-44, 45-64, 65+) — 3 personas each
- **Education groups:** 3/3 covered — 4 personas each
- **Wards:** 12 distinct wards (2, 7, 9, 11, 12, 15, 17, 19, 21, 23, 24, 25)
- **Cells:** 12/12 (age × education) occupied — verified programmatically
- Includes the 5 pilot personas → **40 cache hits** in the baseline condition (free,
  and they make the baseline byte-identical to the pilot for those cells)

No demographic attributes are added, altered, or interpreted. Personas are used exactly
as the simulation pipeline produced them.

## 3. Experimental conditions

Three conditions, **all using the original prompt text unchanged** (`prompt_version=v1`).
Conditions differ only in the *candidate order* inside the prompt, which is already part
of the cache key (`candidate_order`, `order_seed`, `prompt_sha256`) — verified **zero
digest overlap** between all three conditions (0 ∩ 0 ∩ 0), so each condition is its own
cache namespace and none can serve another's results.

| Condition | Order | Rationale |
|---|---|---|
| **C0 — baseline** | `--order ballot` | Exact reproduction of the pilot prompts (40/144 dry-run rows confirmed `from_cache`). Preserves the original prompt as baseline. |
| **C1 — shuffle A** | `--order random --seed 20261026` | Breaks the alphabetical/ballot position structure. |
| **C2 — shuffle B** | `--order random --seed 7777777` | Second independent permutation family (verified: all 12 distinct permutations across seeds × repeats × models for the 53-candidate mayoral race), so "any reordering" can be separated from "this particular permutation". |

Each condition: 12 personas × 2 races × 2 models × 3 repeats = **144 planned requests**.

**Rule for future text-variants (not run now):** if an alternative *wording* is ever
tested (e.g. a knowledge-suppression instruction to probe whether mayoral degeneracy comes
from world knowledge), it must ship as a new `prompt_version` (v2) in `prompts.py` **and**
a distinct config entry, so its cache key and output `prompt_version` column are distinct.
Candidate-order variants do **not** need a new prompt version: the template text is
unchanged and the order is already captured in the cache key and provenance columns.

**Mechanism the three conditions discriminate:**

- If MAYOR-009 keeps winning under **both** random shuffles → degeneracy is
  **knowledge-driven** (the model's prior about the actual incumbent mayor), not position.
- If the winner **tracks list position** across shuffles → degeneracy is
  **order-driven** (first/early-position bias).
- If the winner varies with shuffle but not systematically by position → **sampling
  variation** around a flat-ish distribution.

MAYOR-009 sits at position 9/53 on the ballot, i.e. not first — the pilot alone already
weakens the pure first-position hypothesis; the shuffles make this testable.

## 4. Quantitative diagnostics

All computed per `(race, model, condition)` unless noted; CIs: Wilson 95 % for
proportions, bootstrap over personas (10 000 resamples) for entropy/agreement.

1. **Candidate-choice concentration**
   - Shannon entropy `H = −Σ p̂ᵢ ln p̂ᵢ`; normalized `H/ln K` (K = candidates in race)
   - Effective number of choices `exp(H)`; Herfindahl `Σ p̂ᵢ²`, effective `1/Σ p̂ᵢ²`
   - **Top-1 share** `max p̂ᵢ`; **unique choices U**
   - Degeneracy flag: `U = 1` or top-1 ≥ 0.9
2. **Response diversity**
   - U, normalized entropy, effective #choices; cross-model and cross-condition deltas
   - Full status distribution (valid_choice / undecided / not_voting)
   - **Pairwise agreement** A over all unordered pairs within group (complement of entropy)
3. **Demographic sensitivity** (marginals over age 4 / education 3 / ward 12)
   - Per-stratum top-1 share, U, entropy vs pooled (per age×model×condition cell:
     3 personas × 3 repeats = 9 mayor responses — descriptive only)
   - Jensen–Shannon divergence stratum-vs-pooled; max marginal top-1 gap
   - Measures *whether outputs differ*; never asserts or assumes *why* (no stereotypes)
4. **Provider differences**
   - Status distributions by provider (2×2 valid vs undecided) + Fisher exact,
     Wilson CIs on each rate and on the rate difference
   - Cross-provider pairwise agreement on the same (persona, race, repeat)
   - Entropy / top-1 / U gaps between providers
5. **Repeat disagreement**
   - Within (persona, race, model, condition): agreement over C(3,2) = 3 pairs;
     12 personas → 36 repeat-pairs per (race, model, condition)
   - Decompose: status flips vs choice flips among valid answers
6. **Candidate-order sensitivity**
   - **Chosen-rank distribution**: presented position of the chosen candidate per
     condition (rank 1..K); compare C0 (fixed) vs C1/C2 (varied)
   - **Position-bias coefficient**: Spearman ρ(presented position, selection frequency)
     across candidates, per condition
   - **Order-switch rate**: fraction of paired (persona, race, model, repeat) cells whose
     chosen candidate changes between conditions (C0→C1, C0→C2, C1→C2)
   - **Mayoral mechanism test**: identity/frequency of the winner under each order

Presented order for each request is reconstructable exactly: re-derive the per-request
order seed with `derive_order_seed(base_seed, race_id, model_id, repeat_id)` and
`order_candidates(..., "random", seed)` — the same code paths the runner used (validated
by the digest match), so no stored-prompt parsing is needed.

## 5. Scale and cost estimate (from measured pilot tokens)

Per condition (144 requests), priced with the pilot's measured token counts × config
price table (estimates, reported separately from actual — never summed):

| Component | Requests | Est. cost |
|---|---|---|
| C0 ballot (40 cache hits) | **104 new** | $0.0089 |
| C1 random A | 144 new | $0.0123 |
| C2 random B | 144 new | $0.0123 |
| **Total** | **432 planned, 392 new calls** | **$0.0334** |
| +10 % contingency | — | $0.0367 → **`--budget-usd 0.05`** |

- Cost per condition split: mayor $0.0084 (36+36 requests), own-ward $0.0038 (36+36).
- The budget flag is a **cumulative** cap against the shared cost log; the pilot has
  already spent $0.0034062, so $0.05 covers pilot + full diagnostic (≈ $0.0368 total).
- Fallback if only one shuffle is wanted: C0 + C1 = 288 planned, 248 new, ≈ $0.0212
  (`--budget-usd 0.03`). The 3-condition design is recommended because one shuffle
  cannot separate "reordering in general" from "this permutation".
- Measurements per provider per condition: 72 responses (36 mayor + 36 ward),
  36 repeat-pairs per race.

## 6. What the diagnostic can and cannot establish

**Can:**
- Identify the *mechanism* class of the mayoral degeneracy (knowledge vs position vs
  sampling) — the decision-relevant fact for how the forecast should report mayoral draws.
- Confirm or refute the provider undecided-rate gap's direction and rough magnitude,
  with CIs, at ~1.8× the pilot's n.
- Quantify repeat independence, order sensitivity, and any *existence* of demographic
  variation in outputs at these two models, prompt v1, temperature 0.7.
- Validate the pipeline end-to-end at ~10× pilot scale (cache reuse, budget enforcement,
  provenance columns) before the 36.5k-request production run.

**Cannot:**
- **Generalize to the 3,042-persona frame or population vote shares**: 12 personas, one
  per cell, no within-cell replication; persona is confounded with ward (each cell is a
  different person in a different ward), so demographic effects are not separable from
  individual variation.
- **Detect small effects**: with n = 36 per provider per condition, a 0/36 rate has an
  upper 95 % bound ≈ 8 % (rule of three); differences of a few percentage points are
  undetectable. A null demographic result is *not* evidence of insensitivity.
- **Estimate entropy precisely**: n = 36 observations over a 53-class space → wide
  bootstrap CIs; treat entropy/U as comparative across conditions, not absolute.
- **Causal attribution**: no manipulation of persona text or candidate attributes; and
  order is sampled from only 6 permutations (2 seeds × 3 repeats) — order-bias estimates
  carry wide uncertainty.
- **Voter validity**: LLM outputs are model behavior, not voter intentions; no ground
  truth is claimed or tested here.

## 7. Exact dry-run commands (executed; re-runnable free)

```bash
cd /Users/zhongjingwen/Desktop/MScAC/STA2453/toronto-election-forecast

# C0 — baseline (ballot order, byte-identical to pilot prompts)
env -u OPENROUTER_API_KEY python3 -m llm.runner run --config llm/models.json \
  --selection stratified --selection-seed 20261026 --max-personas 12 \
  --repeats 3 --order ballot --seed 20261026 --dry-run --preview 0 \
  --budget-usd 0.05 --out processed/diagnostic/ballot/out.parquet

# C1 — shuffle A
env -u OPENROUTER_API_KEY python3 -m llm.runner run --config llm/models.json \
  --selection stratified --selection-seed 20261026 --max-personas 12 \
  --repeats 3 --order random --seed 20261026 --dry-run --preview 0 \
  --budget-usd 0.05 --out processed/diagnostic/random_a/out.parquet

# C2 — shuffle B
env -u OPENROUTER_API_KEY python3 -m llm.runner run --config llm/models.json \
  --selection stratified --selection-seed 20261026 --max-personas 12 \
  --repeats 3 --order random --seed 7777777 --dry-run --preview 0 \
  --budget-usd 0.05 --out processed/diagnostic/random_b/out.parquet
```

**Verified results of these dry-runs (all executed, no API key present):**

| Condition | Rows | `from_cache` | New | Unique digests |
|---|---|---|---|---|
| C0 ballot | 144 | 40 | 104 | 144/144 |
| C1 random A | 144 | 0 | 144 | 144/144 |
| C2 random B | 144 | 0 | 144 | 144/144 |

Cross-condition digest overlap: 0 for all three pairs. Pilot files unchanged after all
runs; cost log unchanged (40 entries, $0.0034062).

**Live commands (require explicit approval — NOT run):** identical commands with
`--dry-run` removed; each condition writes to its own output file so nothing overwrites
the pilot:

```bash
# after approval — one at a time, inspect between runs
env -u OPENROUTER_API_KEY python3 -m llm.runner run ... --order ballot \
  --out processed/diagnostic/c0_ballot_responses.parquet
```

(`OPENROUTER_API_KEY` must be set in the environment for live runs; it is never written
to any output.)

**Housekeeping note:** `processed/llm/run_summary.json` is a shared "last run" file that
every run overwrites. The pilot's copy is archived at
`processed/llm/run_summary_pilot40.json` (and was restored after the dry-runs);
per-condition dry-run summaries are in `processed/diagnostic/*_run_summary.json`.

## 8. Analysis plan (after approval and execution)

1. **Ingest**: read the three output parquets; C0 self-contains the 40 pilot rows as
   `from_cache=True`. Concatenate with a `condition` column. No file is overwritten.
2. **Format/validity gate**: re-run the pilot's validity checks (JSON, candidate IDs,
   required columns, `validate_llm_responses`) per condition.
3. **Concentration table**: for each (race × model × condition): U, top-1, H, H/ln K,
   exp(H), Σp̂², pairwise agreement + CIs. Primary read: mayoral U and top-1 across
   C0/C1/C2.
4. **Order diagnostics**: reconstruct presented order per request (seed derivation as
   above); chosen-rank distributions, Spearman position-bias ρ, order-switch rates
   pairwise across conditions; mayoral winner identity per condition.
5. **Provider table**: status distributions + Fisher exact, cross-provider agreement,
   entropy gaps — per condition.
6. **Repeat table**: within-cell agreement (36 pairs per race × model × condition),
   flip decomposition (status vs choice).
7. **Demographic table**: age / education / ward marginals of top-1, U, entropy, status;
   JSD vs pooled. Reported with explicit small-n caveats from §6.
8. **Decision rules for scaling** (pre-registered):
   - Winner invariant across all three orders → knowledge-driven degeneracy: report
     mayoral forecasts as effectively single-candidate-model output with a limitation
     note; no methodology change (methodology is fixed by the assignment constraints).
   - Winner tracks position → document order sensitivity as a measurement limitation
     with quantified switch rate.
   - Provider undecided gap persists → keep both providers, report per-model status
     rates in the write-up.
   - Any format/validity failure > 0 in a condition → stop and investigate before
     production.
9. **Deliverable**: a diagnostic report (metrics tables + verdicts per rule). The
   production run (36 504 requests, ≈ $3.11 estimated) remains blocked on separate
   explicit approval.

## 9. Constraints honored

- No API calls were made while preparing this design (dry-runs run with
  `env -u OPENROUTER_API_KEY`; verified by unchanged cost log).
- No changes to the statistical forecasting pipeline, raw Census data, historical
  election data, prompts, or `processed/simulated/` outputs.
- Pilot responses not overwritten (md5 verified before/after).
- No new model IDs; config unchanged.
- Nothing committed or pushed — this document and `processed/diagnostic/` are untracked.
- Live execution requires explicit user approval, per condition, as always.
