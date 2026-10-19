# Task 6C — Final forecast validation report

## Inputs and method

- Response file: `processed/production/llm_responses.parquet` (md5 `420c3051da6c9a291f5fcf7b587e06bf`)
- Rows: 36504 | personas: 3042 | providers: google/gemini-2.5-flash-lite, openai/gpt-4o-mini | repeats: 3
- Uncertainty method: **centered** (perturbation target SD = 0.04)
- Draws per race x provider: 500; base seed: 245309 (provider m uses seed + m; sensitivity uses the same seeds = common random numbers)

Variance sources (explicitly distinguished):

1. **LLM response variability** — each draw resamples one of the
   provider's 3 repeat cells (within-provider; provider disagreement
   is reported separately, never averaged away).
2. **Dirichlet sampling uncertainty** — share ~
   Dirichlet(n_eff * share + 0.5) with the Kish effective sample size.
3. **Assumed forecast perturbation** (Method C) — multiplicative
   logistic-normal s_k <- s_k * exp(sigma * eps_k), eps ~ N(0,1),
   renormalised; sigma calibrated per race so this layer alone gives
   the leader an sd of the target SD above.
4. **Real election uncertainty — NOT modelled.** Intervals and
   win frequencies are conditional on the LLM responses and the
   assumed perturbation scale; they are illustrative simulation
   frequencies, not calibrated probabilities for a real election.

## Output shapes

- `cell_estimates.parquet`: 1458 rows
- `candidate_point_estimates.parquet`: 486 rows (provider-specific, equal weight over repeats)
- `pooled_point_estimates_descriptive.parquet`: 243 rows (labelled descriptive, equal weight over 6 cells)
- `forecast_draws_centered.parquet`: 243000 rows
- `forecast_summary_centered.parquet`: 486 rows
- `centering_bias_centered.parquet`: 52 rows
- `sensitivity_target_sd.parquet`: 1458 rows (3 target SDs)
- `pseudocount_effect.parquet`: 52 rows

## Validation checks

| check | status | detail |
|---|---|---|
| production responses preserved (md5) | PASS | md5 420c3051da6c9a291f5fcf7b587e06bf |
| production response rows == 36,504 | PASS | 36504 |
| production personas covered == 3,042 | PASS | 3042 |
| all census population cells covered == 300 | PASS | frame 300, with responses 300 |
| races: outputs == crosswalk | PASS | 26 of 26 |
| candidate grid: 243 candidates / 26 races in crosswalk | PASS | 243 candidates / 26 races |
| summary rows == candidates x providers | PASS | 486 (expect 486) |
| provider point-estimate rows == candidates x providers | PASS | 486 |
| descriptive pooled point rows == candidates | PASS | 243 |
| draw rows == candidates x providers x n_draws | PASS | 243000 (expect 243000) |
| every draw vector sums to 1 | PASS | max |sum-1| = 1.443e-15 |
| no NA/NaN in draws | PASS | none |
| shares within [0, 1] | PASS | [0.000000, 0.998911] |
| draw candidate IDs all valid | PASS | 0 invalid pairs |
| provider-specific p_win sums to 1 per race x provider | PASS | max |sum-1| = 1.110e-16 |
| cell estimate shares sum to 1 | PASS | max |sum-1| = 3.109e-15 |
| Dirichlet n_eff positive in all cells | PASS | min n_eff = 78.7 |
| sensitivity row at target_sd reproduces production summary | PASS | max abs diff = 0.000e+00 |
| sensitivity grid complete (0.02 / 0.04 / 0.06) | PASS | 0.02, 0.04, 0.06 |
| max leader-centring bias is reported (not assumed zero) | PASS | max |leader bias| = 5.74 pp |
| max leader-centring bias within 10pp sanity bound | PASS | 5.74 pp |
| fixed seed reproduces byte-identical draws | PASS | provider google/gemini-2.5-flash-lite |

## Leader-centring bias (reported, not assumed zero)

Method C is only **approximately** centre-preserving. The realised maximum |leader bias| is **5.74 pp** (worst: ward_19_councillor / google/gemini-2.5-flash-lite).
For reference, the original additive-noise construction (A) showed up to ~38 pp leader bias on the mayoral race in the Task 6B comparison.

## Dirichlet +0.5 pseudocount effect (5 worst races by observed bias)


| race | provider | K | n_eff (min) | pseudocount mass | theory shrink | observed Dirichlet bias | observed Method C bias |
|---|---|---|---|---|---|---|---|
| ward_19_councillor | google/gemini-2.5-flash-lite | 13 | 114.3 | 5.38% | -4.68 pp | -4.68 pp | -5.74 pp |
| ward_14_councillor | google/gemini-2.5-flash-lite | 18 | 78.7 | 8.33% | -4.02 pp | -4.35 pp | -2.77 pp |
| ward_21_councillor | openai/gpt-4o-mini | 11 | 100.9 | 5.12% | -2.92 pp | -3.45 pp | -2.00 pp |
| ward_19_councillor | openai/gpt-4o-mini | 13 | 104.3 | 5.71% | -2.33 pp | -3.05 pp | -3.07 pp |
| ward_13_councillor | google/gemini-2.5-flash-lite | 11 | 140.2 | 3.78% | -1.70 pp | -2.95 pp | -2.42 pp |

## Method C sensitivity to the perturbation target SD


| target SD | median leader 95% width | median leader sd | leader p_win = 1 |
|---|---|---|---|
| 0.02 | 33.62 pp | 9.89 pp | 21 of 52 |
| 0.04 | 37.27 pp | 10.53 pp | 15 of 52 |
| 0.06 | 41.01 pp | 11.57 pp | 12 of 52 |

## Limitations

- Uncertainty is **not calibrated** to historical election or
  polling error; p_win values are simulation frequencies under the
  stated model, not real winning probabilities.
- The Dirichlet +0.5 prior shrinks low-n_eff, many-candidate wards
  toward uniform (see table above); point estimates are unchanged,
  so this shrinkage affects draws only.
- Provider disagreement dominates method differences in several
  races; provider-specific forecasts must be read separately.
- The mayoral race is effectively degenerate in the source responses
  (mode collapse measured in Task 5/6A); no uncertainty method can
  honestly manufacture competitiveness from it.
- Undecided responses are excluded from estimation (decided-share
  target); no nonresponse adjustment is applied.
