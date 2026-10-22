# 09_poststratify_forecast.R
#
# Demographic post-stratification of the simulated responses, followed by
# Monte Carlo forecast draws.
#
# Estimation target (documented explicitly):
#   each candidate's share of VALID (decided) first preferences in the
#   race's elector population, with every persona carrying its Census
#   design weight.
#
#     share_k = sum_i w_i * 1[choice_i = k] / sum_i w_i
#
# over valid_choice responses only. Treatment of non-valid responses:
#   - undecided / not_voting: excluded from numerator AND denominator
#     (target is decided-voter share, not turnout share);
#   - missing / invalid: excluded from estimation but RETAINED in the
#     response dataset for audit;
#   - empty cells: a cell in which no persona gives a valid response
#     contributes no weight; the estimate renormalises over responding
#     cells (all 300 cells have positive persona representation).
#
# Ward councillor races sum over that ward's personas. The mayoral race
# sums over ALL personas with citywide weights, so wards enter in
# proportion to their 20+ population -- wards are never equally sized.
#
# Forecast draws (see generate_forecast_draws()) separate:
#   1. model/provider variation (resample provider x repeat cell),
#   2. response sampling variability (Dirichlet, Kish n_eff scale),
#   3. assumed forecast uncertainty (Gaussian share noise, 3pp, sd).
# The draws are ILLUSTRATIVE simulation output, NOT calibrated election
# uncertainty.
#
# Outputs:
#   processed/simulated/simulated_forecast_draws.parquet
#   processed/simulated/simulated_forecast_summary.parquet
#
# Fixed seed: SIM_SEEDS$forecast.

library(dplyr)
library(readr)
library(tidyr)
library(nanoparquet)

source(file.path("R", "simulation_helpers.R"))

message("==> 09: Post-stratifying and generating forecast draws")

personas <- read_parquet(
  file.path("processed", "simulated", "simulated_personas.parquet")
)

responses <- read_parquet(
  file.path("processed", "simulated", "simulated_responses.parquet")
)

crosswalk <- read_parquet(
  file.path("processed", "simulated", "candidate_crosswalk.parquet")
)

post <- poststratify_responses(responses, personas, crosswalk)

draws <- generate_forecast_draws(post$cells, seed = SIM_SEEDS$forecast)

summary_tbl <- summarise_forecast_draws(draws, post$point)

# Validation guards.
stopifnot(
  # Point shares sum to 1 among valid choices, per race.
  all(abs(post$point |>
    group_by(race_id) |>
    summarise(s = sum(point_share)) |>
    pull(s) - 1) < 1e-9),
  # Shares are valid probabilities.
  all(draws$share >= 0 & draws$share <= 1),
  all(summary_tbl$point_share >= 0 & summary_tbl$point_share <= 1),
  # Multiple repetitions present.
  n_distinct(draws$draw_id) == FORECAST_DRAWS_PER_RACE,
  n_distinct(draws$source_model_id) == nrow(PROVIDER_MODELS),
  n_distinct(draws$source_repeat_id) == N_REPEATS,
  # Every draw vector sums to 1 (spot-check one race).
  abs(sum(draws$share[draws$race_id == "mayor" &
    draws$draw_id == 1]) - 1) < 1e-9
)

dir.create(file.path("processed", "simulated"), showWarnings = FALSE)

write_parquet(
  draws,
  file.path("processed", "simulated", "simulated_forecast_draws.parquet")
)

write_parquet(
  summary_tbl,
  file.path("processed", "simulated", "simulated_forecast_summary.parquet")
)

message(
  sprintf(
    "    %d draws x %d races; %d summary rows",
    FORECAST_DRAWS_PER_RACE, n_distinct(draws$race_id), nrow(summary_tbl)
  )
)
