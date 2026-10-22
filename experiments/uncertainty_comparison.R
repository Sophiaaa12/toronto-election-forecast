# experiments/uncertainty_comparison.R
#
# Task 6B — ISOLATED experimental comparison of uncertainty constructions
# for the LLM post-stratified forecasts. This script:
#
#   * READS production LLM responses (processed/production/llm_responses.parquet),
#     the persona frame and the candidate crosswalk read-only;
#   * reuses the UNCHANGED poststratify_responses() from R/simulation_helpers.R
#     so the post-stratified point estimates are exactly the pipeline's;
#   * implements THREE draw-generating methods locally (no pipeline file is
#     modified, no pipeline output is written):
#
#       A (existing) : Dirichlet(n_eff * share + 0.5)
#                      -> + iid N(0, 0.03^2) per candidate
#                      -> clip at 0 -> renormalise          [generate_forecast_draws]
#       B (dirichlet): Dirichlet(n_eff * share + 0.5)        [same, minus noise]
#       C (centered) : Dirichlet(n_eff * share + 0.5)  [sampling layer]
#                      -> multiplicative logistic-normal perturbation
#                         s_k <- s_k * exp(sigma * eps_k), eps ~ N(0,1)
#                         [forecast layer, simplex-preserving, zero-support
#                          candidates keep exact mass 0]
#                         sigma calibrated per race so the forecast layer alone
#                         gives the race leader an sd of TARGET_FORECAST_SD.
#
#   * keeps the two providers SEPARATE: draws for a (race, model) cell resample
#     only that model's three repeat cells (the production pipeline resamples
#     across all 6 provider x repeat cells; per-model draws isolate provider
#     sensitivity, per Task 6B item 6).
#
# Outputs (new files only): experiments/output/*.csv and printed tables.
# Nothing under processed/ is written; no LLM APIs are called.

suppressMessages({
  library(dplyr)
  library(tidyr)
  library(nanoparquet)
})

source("R/simulation_helpers.R")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
N_DRAWS <- 2000 # per (race, model, method); pipeline uses 500
TARGET_FORECAST_SD <- 0.04 # C: target sd (4pp) for the race leader under
#    the forecast layer alone
FOCUS_RACES <- c(
  "mayor", # K = 53 (collapse + high-K artifact)
  "ward_02_councillor", # K = 3  (few candidates)
  "ward_14_councillor", # K = 18 (many candidates, low n_eff)
  "ward_20_councillor"
) # K = 8  (closest pooled margin, 1.4pp)
OUT_DIR <- file.path("experiments", "output")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

set.seed(20261018)

# ---------------------------------------------------------------------------
# Data (read-only) and unchanged post-stratification
# ---------------------------------------------------------------------------
res <- read_parquet(file.path("processed", "production", "llm_responses.parquet"))
per <- read_parquet(file.path("processed", "simulated", "simulated_personas.parquet"))
cw <- read_parquet(file.path("processed", "simulated", "candidate_crosswalk.parquet"))

post <- poststratify_responses(res, per, cw,
  model_ids = sort(unique(res$model_id)),
  n_repeats = max(res$repeat_id)
)
cells <- post$cells
points <- post$point
model_ids <- sort(unique(res$model_id))

K_CAND <- cw |> count(race_id, name = "n_candidates")

# Per (race, model): share matrix over repeats, neff vector, model-internal
# center (equal average of the model's repeat-cell shares).
build_cell_arrays <- function(race, model) {
  est <- cells |> filter(race_id == race, model_id == model)
  reps <- sort(unique(est$repeat_id))
  cands <- sort(unique(est$candidate_id))
  share_mat <- matrix(0, length(reps), length(cands))
  neff_vec <- numeric(length(reps))
  for (j in seq_along(reps)) {
    row <- est |> filter(repeat_id == reps[j])
    share_mat[j, ] <- row$share[match(cands, row$candidate_id)]
    neff_vec[j] <- row$n_eff[1]
  }
  list(reps = reps, cands = cands, share_mat = share_mat, neff_vec = neff_vec)
}

# ---------------------------------------------------------------------------
# Calibrate sigma for method C: binary search so that the multiplicative
# layer alone (applied to the race's POOLED point vector) gives the leader
# an sd of TARGET_FORECAST_SD. Exact zeros keep exact zero mass.
# ---------------------------------------------------------------------------
calibrate_sigma <- function(p, target_sd, n_pilot = 20000) {
  L <- which.max(p)
  pilot_sds <- function(sig) {
    e <- matrix(rnorm(n_pilot * length(p), sd = sig), nrow = n_pilot)
    P <- matrix(p, nrow = n_pilot, ncol = length(p), byrow = TRUE)
    w <- P * exp(e) # p == 0 stays exactly 0
    s <- w / rowSums(w)
    sd(s[, L])
  }
  if (pilot_sds(1e-4) >= target_sd) {
    return(1e-4)
  }
  if (pilot_sds(10) <= target_sd) {
    return(10)
  } # saturation guard
  uniroot(function(x) pilot_sds(x) - target_sd, interval = c(1e-4, 10))$root
}

sigmas <- points |>
  group_by(race_id) |>
  summarise(sigma = calibrate_sigma(point_share, TARGET_FORECAST_SD), .groups = "drop")

# ---------------------------------------------------------------------------
# Draw generator for one (race, model) under one method.
# Returns a list with the pooled draw matrix (n_draws * n_repeats rows),
# per-draw total mass on zero-support (of the source cell) candidates, and
# the source-cell repeat per draw.
# ---------------------------------------------------------------------------
draw_race_model <- function(arr, method, n_draws, sigma, noise_sd) {
  n_rep <- length(arr$reps)
  n_cand <- length(arr$cands)
  dm <- matrix(0, n_draws * n_rep, n_cand)
  zer <- numeric(n_draws * n_rep)
  src <- integer(n_draws * n_rep)
  row <- 0L
  for (j in seq_len(n_rep)) {
    alpha_base <- arr$neff_vec[j] * arr$share_mat[j, ] + DIRICHLET_PSEUDOCOUNT
    zero_mask <- arr$share_mat[j, ] == 0
    for (d in seq_len(n_draws)) {
      row <- row + 1L
      s <- rgamma(n_cand, shape = alpha_base)
      s <- s / sum(s)
      if (method == "A") {
        s <- s + rnorm(n_cand, sd = noise_sd)
        s <- pmax(s, 0)
        s <- s / sum(s)
      } else if (method == "C") {
        s <- s * exp(sigma * rnorm(n_cand))
        s <- s / sum(s)
      }
      dm[row, ] <- s
      zer[row] <- sum(s[zero_mask])
      src[row] <- j
    }
  }
  list(draws = dm, zero_mass = zer, src_rep = arr$reps[src])
}

# ---------------------------------------------------------------------------
# Sweep all (race, model, method); collect metrics. Focus races also keep
# per-candidate summaries. Method timing accumulated over the whole sweep.
# ---------------------------------------------------------------------------
races <- sort(unique(cells$race_id))

metrics_list <- list()
focus_list <- list()
timing <- c(A = 0, B = 0, C = 0)

for (method in c("A", "B", "C")) {
  t0 <- proc.time()[["elapsed"]]
  for (race in races) {
    point_race <- points |> filter(race_id == race)
    cands <- sort(point_race$candidate_id)
    p_pool <- point_race$point_share[match(cands, point_race$candidate_id)]
    sigma <- sigmas$sigma[sigmas$race_id == race]
    for (model in model_ids) {
      arr <- build_cell_arrays(race, model)
      stopifnot(identical(arr$cands, cands))
      model_center <- colMeans(arr$share_mat) # equal avg over repeat cells
      g <- draw_race_model(arr, method, N_DRAWS, sigma, ASSUMED_FORECAST_SD)
      dm <- g$draws
      L <- which.max(p_pool)
      mean_s <- colMeans(dm)
      sd_s <- apply(dm, 2, sd)
      q <- apply(dm, 2, quantile, probs = c(0.025, 0.975))
      # winning frequency: candidate index of row max per draw
      winner_idx <- max.col(dm, ties.method = "first")
      p_win <- tabulate(winner_idx, nbins = length(cands)) / nrow(dm)
      metrics_list[[length(metrics_list) + 1]] <- data.frame(
        race_id = race, model_id = model, method = method,
        n_cand = length(cands),
        n_eff_med = median(arr$neff_vec),
        leader_point = p_pool[L],
        leader_mean = mean_s[L],
        leader_bias_pp = 100 * (mean_s[L] - model_center[L]),
        leader_bias_vs_pooled_pp = 100 * (mean_s[L] - p_pool[L]),
        leader_sd = sd_s[L],
        leader_width95 = 100 * (q[2, L] - q[1, L]),
        med_width95_active = 100 * median((q[2, ] - q[1, ])[p_pool >= 0.01]),
        mean_abs_bias_active_pp = 100 * mean(abs(mean_s - model_center)[p_pool >= 0.01]),
        zero_mass = mean(g$zero_mass),
        leader_p_win = p_win[L],
        p_win_entropy = -sum(p_win[p_win > 0] * log(p_win[p_win > 0])),
        stringsAsFactors = FALSE
      )
      if (race %in% FOCUS_RACES) {
        focus_list[[length(focus_list) + 1]] <- data.frame(
          race_id = race, model_id = model, method = method,
          candidate_id = cands,
          point_share = p_pool, model_center = model_center,
          mean_share = mean_s, sd_share = sd_s,
          q025 = q[1, ], q975 = q[2, ], p_win = p_win,
          stringsAsFactors = FALSE
        )
      }
    }
  }
  timing[method] <- proc.time()[["elapsed"]] - t0
}

metrics <- bind_rows(metrics_list) |> left_join(K_CAND, by = "race_id")
focus <- bind_rows(focus_list)

write.csv(metrics, file.path(OUT_DIR, "method_metrics_all_races.csv"), row.names = FALSE)
write.csv(focus, file.path(OUT_DIR, "method_focus_races.csv"), row.names = FALSE)
write.csv(sigmas |> left_join(K_CAND, by = "race_id"),
  file.path(OUT_DIR, "calibrated_sigmas.csv"),
  row.names = FALSE
)

cat("\n================ RESULTS ================\n\n")

cat("--- 1. Pseudocount (Dirichlet +0.5 prior) shrinkage ---\n")
shrink <- cells |>
  distinct(race_id, model_id, repeat_id, n_eff) |>
  left_join(K_CAND, by = "race_id") |>
  mutate(pseudocount_mass = (DIRICHLET_PSEUDOCOUNT * n_candidates) /
    (n_eff + DIRICHLET_PSEUDOCOUNT * n_candidates)) |>
  filter(race_id %in% FOCUS_RACES)
print(as.data.frame(shrink |> group_by(race_id) |>
  summarise(
    n_eff_min = min(n_eff), n_eff_max = max(n_eff),
    n_candidates = first(n_candidates),
    pseudocount_mass_pct = round(100 * mean(pseudocount_mass), 2),
    .groups = "drop"
  )))

cat("\n--- 2. FOCUS RACES: leader metrics (per provider x method) ---\n")
foc <- metrics |>
  filter(race_id %in% FOCUS_RACES) |>
  select(
    race_id, model_id, method, n_cand, leader_point, leader_mean,
    leader_bias_pp, leader_sd, leader_width95, leader_p_win, zero_mass
  ) |>
  mutate(across(where(is.numeric), ~ round(., 4)))
print(as.data.frame(foc |> arrange(race_id, method, model_id)))

cat("\n--- 3. Close race (ward_20): full p_win vectors ---\n")
w20 <- focus |>
  filter(race_id == "ward_20_councillor", p_win > 0.001) |>
  select(
    race_id, model_id, method, candidate_id, point_share, mean_share,
    q025, q975, p_win
  ) |>
  mutate(across(where(is.numeric), ~ round(., 4)))
print(as.data.frame(w20 |> arrange(candidate_id, method, model_id)))

cat("\n--- 4. K-dependence across all 26 races (Spearman corr with K) ---\n")
kdep <- metrics |>
  group_by(method) |>
  summarise(
    cor_K_leader_bias = round(cor(n_cand, abs(leader_bias_pp), method = "spearman"), 3),
    cor_K_leader_width = round(cor(n_cand, leader_width95, method = "spearman"), 3),
    cor_K_zero_mass = round(cor(n_cand, zero_mass, method = "spearman"), 3),
    max_leader_bias_pp = round(max(abs(leader_bias_pp)), 2),
    median_leader_width_pp = round(median(leader_width95), 2),
    races_pwin_eq_1 = sum(leader_p_win == 1),
    races_pwin_ge_095 = sum(leader_p_win >= 0.95),
    .groups = "drop"
  )
print(as.data.frame(kdep))

cat("\n--- 5. Provider sensitivity: |gpt - gemini| in leader stats ---\n")
m1 <- model_ids[1]
m2 <- model_ids[2]
prov <- metrics |>
  select(race_id, model_id, method, leader_mean, leader_p_win, leader_sd) |>
  pivot_longer(c(leader_mean, leader_p_win, leader_sd), names_to = "stat", values_to = "v") |>
  pivot_wider(names_from = model_id, values_from = v) |>
  mutate(abs_diff = abs(.data[[m1]] - .data[[m2]])) |>
  group_by(method, stat) |>
  summarise(
    median_diff = round(median(abs_diff), 4),
    max_diff = round(max(abs_diff), 4),
    max_race = race_id[which.max(abs_diff)], .groups = "drop"
  )
print(as.data.frame(prov))

cat("\n--- 6. Computational cost (full 26-race x 2-model sweep, ", N_DRAWS,
  " draws/cell) ---\n",
  sep = ""
)
print(round(timing, 2))
cat("\n(sigmas calibrated per race for C; see experiments/output/calibrated_sigmas.csv)\n")
print(as.data.frame(sigmas |> filter(race_id %in% FOCUS_RACES) |>
  mutate(across(where(is.numeric), ~ round(., 4)))))
cat("\nDone. Outputs written to experiments/output/ (new files only).\n")
