# R/10_llm_poststratify.R
#
# Bridge from REAL LLM responses to the forecast pipeline (Task 6C).
#
# This script is the hand-off point between the Python OpenRouter
# sampling layer (llm/runner.py) and the R statistical layer. It:
#
#   1. reads the LLM response parquet (production default:
#      processed/production/llm_responses.parquet);
#   2. VALIDATES it against the schema expected by the simulation
#      pipeline (required columns, status vocabulary, candidate/race
#      membership, persona coverage);
#   3. runs the UNCHANGED post-stratification (poststratify_responses)
#      and then one of the reviewed draw generators:
#        uncertainty = "centered"  -> generate_forecast_draws_centered()
#                                     (Method C, production default)
#        uncertainty = "existing"  -> generate_forecast_draws_existing()
#                                     (original additive-noise construction,
#                                      evaluated per provider)
#        uncertainty = "dirichlet" -> generate_forecast_draws_dirichlet()
#                                     (sampling uncertainty only)
#      plus a target-SD sensitivity analysis for Method C
#      (FORECAST_TARGET_SD_GRID: 0.02 / 0.04 / 0.06);
#   4. writes everything to a SEPARATE directory
#      (processed/forecast/, ...) with method-tagged filenames, and
#      REFUSES to overwrite an existing file unless overwrite = TRUE --
#      no mock, pilot, diagnostic or production artifact is ever touched.
#
# Point estimates:
#   - provider-specific forecasts use provider point shares (equal weight
#     over that provider's 3 repeat cells);
#   - a separately labelled DESCRIPTIVE equal-weight pooled point estimate
#     (mean over all 6 provider x repeat cells) is written alongside the
#     original poststratified pool for reference. Draws are never pooled
#     across providers.
#
# Usage:
#   Rscript R/10_llm_poststratify.R [llm_path] [uncertainty]
#   e.g.
#   Rscript R/10_llm_poststratify.R \
#     processed/production/llm_responses.parquet centered
#
# Inputs:
#   processed/production/llm_responses.parquet   (from llm/runner.py)
#   processed/simulated/simulated_personas.parquet   (design weights)
#   processed/simulated/candidate_crosswalk.parquet  (candidate grid)
#
# Outputs (all under processed/forecast/):
#   cell_estimates.parquet                     (method-independent)
#   candidate_point_estimates.parquet          (provider-specific)
#   pooled_point_estimates_descriptive.parquet (labelled descriptive)
#   forecast_draws_<uncertainty>.parquet
#   forecast_summary_<uncertainty>.parquet
#   centering_bias_<uncertainty>.parquet       (realised bias, REPORTED)
#   sensitivity_target_sd.parquet              (Method C, 0.02/0.04/0.06)
#   pseudocount_effect.parquet                 (+0.5 prior diagnostics)
#   validation_report.md

library(dplyr)
library(nanoparquet)

source(file.path("R", "simulation_helpers.R"))

# md5 of the frozen production response dataset (36,504 rows). Checked on
# every run whose llm_path is the production default, so Task 6C
# requirement "preserve all 36,504 production LLM responses" is enforced
# mechanically. Update this constant ONLY if the production file is
# deliberately replaced through an approved process.
PRODUCTION_LLM_PATH <- file.path("processed", "production", "llm_responses.parquet")
PRODUCTION_LLM_MD5 <- "420c3051da6c9a291f5fcf7b587e06bf"

# ---------------------------------------------------------------------------
# Validation helpers (pure functions; unit-tested in
# tests/testthat/test-10_llm_bridge.R)
# ---------------------------------------------------------------------------

# Minimum columns required to reuse the simulation pipeline.
LLM_REQUIRED_COLS <- c(
  "persona_id", "ward", "race_id", "candidate_id", "provider_id",
  "model_id", "repeat_id", "response_status"
)

# The three statuses a MODEL may produce. Technical failures
# (missing/invalid/timeout/rate_limit/api_error) are retained in the
# file for audit but never counted as answers.
LLM_MODEL_STATUSES <- c("valid_choice", "undecided", "not_voting")

LLM_FAILURE_STATUSES <- c(
  "missing", "invalid", "timeout", "rate_limit", "api_error"
)

LLM_ALL_STATUSES <- c(LLM_MODEL_STATUSES, LLM_FAILURE_STATUSES)

# Validate the LLM response table. Returns a character vector of
# problems (empty = valid). Deliberately returns issues rather than
# stopping so tests can assert on specific failures.
validate_llm_responses <- function(responses, crosswalk) {
  problems <- character(0)

  missing_cols <- setdiff(LLM_REQUIRED_COLS, names(responses))
  if (length(missing_cols) > 0) {
    return(paste("missing required columns:", paste(missing_cols, collapse = ", ")))
  }

  bad_status <- setdiff(unique(responses$response_status), LLM_ALL_STATUSES)
  if (length(bad_status) > 0) {
    problems <- c(
      problems,
      paste("unknown response_status values:", paste(bad_status, collapse = ", "))
    )
  }

  # Candidate IDs must belong to the race they are filed under.
  cand_pairs <- crosswalk |>
    select(race_id, candidate_id) |>
    distinct()
  ans <- responses |>
    filter(response_status == "valid_choice") |>
    select(race_id, candidate_id) |>
    distinct() |>
    anti_join(cand_pairs, by = c("race_id", "candidate_id"))
  if (nrow(ans) > 0) {
    problems <- c(
      problems,
      paste0(
        nrow(ans), " race-candidate pair(s) not in the crosswalk, e.g. ",
        ans$race_id[1], "/", ans$candidate_id[1]
      )
    )
  }

  # valid_choice requires a candidate_id; every other status requires none.
  bad_valid <- responses |>
    filter(response_status == "valid_choice", is.na(candidate_id)) |>
    nrow()
  if (bad_valid > 0) {
    problems <- c(problems, "valid_choice rows with missing candidate_id")
  }
  bad_null <- responses |>
    filter(response_status != "valid_choice", !is.na(candidate_id)) |>
    nrow()
  if (bad_null > 0) {
    problems <- c(
      problems,
      "non-valid_choice rows must have NULL candidate_id"
    )
  }

  # Every persona must exist in the persona file (design weights).
  problems
}

validate_llm_personas <- function(responses, personas) {
  unknown <- setdiff(unique(responses$persona_id), personas$persona_id)
  if (length(unknown) > 0) {
    return(paste0(
      length(unknown), " persona_id(s) not in the persona file, e.g. ",
      unknown[1]
    ))
  }
  character(0)
}

# ---------------------------------------------------------------------------
# Point-estimate builders (post-stratification itself is unchanged)
# ---------------------------------------------------------------------------

# Provider-specific point shares: equal weight over that provider's
# repeat cells (each repeat cell is a complete post-stratified
# distribution). n_valid = total valid responses for race x provider.
build_model_point_estimates <- function(cell_estimates) {
  cell_n <- cell_estimates |>
    distinct(race_id, model_id, repeat_id, n_valid)
  totals <- cell_n |>
    group_by(race_id, model_id) |>
    summarise(n_valid = sum(n_valid), .groups = "drop")
  cell_estimates |>
    group_by(race_id, model_id, candidate_id) |>
    summarise(point_share = mean(share), .groups = "drop") |>
    left_join(totals, by = c("race_id", "model_id"))
}

# DESCRIPTIVE pooled point estimates: equal weight over all 6
# provider x repeat cells, clearly labelled. Kept separate from the
# provider-specific forecasts (draws are never pooled across providers).
# The original poststratified pool (design-weight pool over valid
# responses) is carried alongside for reference.
build_pooled_point_estimates <- function(cell_estimates, poststratified_point) {
  cell_estimates |>
    group_by(race_id, candidate_id) |>
    summarise(pooled_equal_weight_share = mean(share), .groups = "drop") |>
    left_join(
      poststratified_point |>
        select(race_id, candidate_id,
          poststratified_pool_share = point_share
        ),
      by = c("race_id", "candidate_id")
    ) |>
    mutate(
      estimate_type = "descriptive_equal_weight_pooled",
      stringsAsFactors = FALSE
    )
}

# ---------------------------------------------------------------------------
# Output guards: never silently overwrite an existing file.
#   - identical_ok = TRUE (method-independent tables): an existing file
#     whose contents recompute identically is kept with a message; a file
#     that DIFFERS is a hard error.
#   - otherwise: existing file => error unless overwrite = TRUE.
write_forecast_output <- function(x, path, overwrite = FALSE,
                                  identical_ok = FALSE) {
  if (file.exists(path)) {
    if (identical_ok) {
      old <- nanoparquet::read_parquet(path)
      if (isTRUE(all.equal(as.data.frame(old), as.data.frame(x),
        check.attributes = FALSE, tolerance = 1e-9
      ))) {
        message("Existing output unchanged, keeping: ", path)
        return(invisible(FALSE))
      }
      stop(
        "Existing output DIFFERS from the recomputed result: ", path,
        " (refusing to overwrite; inspect before using overwrite = TRUE)"
      )
    }
    if (!overwrite) {
      stop(
        "Refusing to overwrite existing output: ", path,
        " (pass overwrite = TRUE to replace it)"
      )
    }
  }
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  nanoparquet::write_parquet(x, path)
  invisible(TRUE)
}

write_forecast_lines <- function(lines, path, overwrite = FALSE,
                                 identical_ok = TRUE) {
  if (file.exists(path)) {
    if (identical_ok) {
      old <- readLines(path, warn = FALSE)
      if (identical(old, lines)) {
        message("Existing output unchanged, keeping: ", path)
        return(invisible(FALSE))
      }
    }
    if (!overwrite) {
      stop(
        "Refusing to overwrite existing output: ", path,
        " (pass overwrite = TRUE to replace it)"
      )
    }
  }
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  writeLines(lines, path)
  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

run_llm_poststratify <- function(
  llm_path = PRODUCTION_LLM_PATH,
  personas_path = file.path("processed", "simulated", "simulated_personas.parquet"),
  crosswalk_path = file.path("processed", "simulated", "candidate_crosswalk.parquet"),
  out_dir = file.path("processed", "forecast"),
  n_draws = FORECAST_DRAWS_PER_RACE,
  seed = SIM_SEEDS$forecast,
  uncertainty = c("centered", "existing", "dirichlet"),
  target_sd = FORECAST_TARGET_SD,
  sensitivity_grid = FORECAST_TARGET_SD_GRID,
  overwrite = FALSE
) {
  uncertainty <- match.arg(uncertainty)

  if (!file.exists(llm_path)) {
    message(
      "No real LLM responses found at '", llm_path, "'.\n",
      "Produce them with:\n",
      "  python3 -m llm.runner run --config llm/models.json --budget-usd <N>\n",
      "then re-run:\n",
      "  Rscript R/10_llm_poststratify.R"
    )
    return(invisible(NULL))
  }

  responses <- read_parquet(llm_path)
  personas <- read_parquet(personas_path)
  crosswalk <- read_parquet(crosswalk_path)

  problems <- c(
    validate_llm_responses(responses, crosswalk),
    validate_llm_personas(responses, personas)
  )
  if (length(problems) > 0) {
    stop(
      "LLM response validation failed:\n",
      paste0("  - ", problems, collapse = "\n")
    )
  }

  # Preservation check: the frozen production dataset must not change.
  is_production <- identical(
    normalizePath(llm_path, mustWork = FALSE),
    normalizePath(PRODUCTION_LLM_PATH, mustWork = FALSE)
  )
  production_md5 <- NA_character_
  if (is_production) {
    production_md5 <- unname(tools::md5sum(llm_path))
    if (!identical(production_md5, PRODUCTION_LLM_MD5)) {
      stop(
        "Production response file changed on disk!\n",
        "  expected md5: ", PRODUCTION_LLM_MD5, "\n",
        "  found md5:    ", production_md5, "\n",
        "Production LLM responses must be preserved byte-for-byte."
      )
    }
  }

  # Derive the model/repeat grid actually present in the data so the
  # same statistics apply regardless of configuration.
  model_ids <- sort(unique(responses$model_id))
  n_repeats <- max(responses$repeat_id, na.rm = TRUE)

  post <- poststratify_responses(
    responses  = responses,
    personas   = personas,
    crosswalk  = crosswalk,
    model_ids  = model_ids,
    n_repeats  = n_repeats
  )
  cell_estimates <- post$cells
  model_points <- build_model_point_estimates(cell_estimates)
  pooled_points <- build_pooled_point_estimates(cell_estimates, post$point)

  # Reference shares used ONLY to calibrate Method C's sigma per race
  # (equal-weight pooled descriptive shares).
  calibration_points <- pooled_points |>
    transmute(race_id, candidate_id,
      point_share = pooled_equal_weight_share
    )

  # Race leaders per provider (centering-bias + sensitivity reporting).
  leaders <- model_points |>
    group_by(race_id, model_id) |>
    slice_max(point_share, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(race_id, model_id, leader_candidate = candidate_id)

  # Provider-specific draws. Each provider gets an independent seed
  # (seed + provider index) so provider RNG streams are independent;
  # the same provider+seed reproduces byte-identical draws.
  draw_fun <- switch(uncertainty,
    centered = function(m, s) {
      generate_forecast_draws_centered(
        cell_estimates, calibration_points, m,
        seed = s, n_draws = n_draws, target_sd = target_sd
      )
    },
    existing = function(m, s) {
      generate_forecast_draws_existing(
        cell_estimates, m,
        seed = s, n_draws = n_draws
      )
    },
    dirichlet = function(m, s) {
      generate_forecast_draws_dirichlet(
        cell_estimates, m,
        seed = s, n_draws = n_draws
      )
    }
  )
  draws <- bind_rows(
    lapply(seq_along(model_ids), function(mi) draw_fun(model_ids[mi], seed + mi))
  )
  summary_tbl <- summarise_provider_draws(draws, model_points)
  bias_tbl <- forecast_centering_bias(draws, model_points)
  max_bias_pp <- max(abs(bias_tbl$leader_bias_pp))

  # Sensitivity analysis for Method C's assumed perturbation target SD
  # (common random numbers across targets: identical seeds, so target-SD
  # differences are not contaminated by Monte Carlo noise). The row at
  # target == target_sd must reproduce the production summary exactly.
  sensitivity_tbl <- NULL
  sensitivity_agg <- NULL
  if (uncertainty == "centered") {
    sens_list <- vector("list", length(sensitivity_grid))
    for (ti in seq_along(sensitivity_grid)) {
      t <- sensitivity_grid[ti]
      dr <- bind_rows(lapply(seq_along(model_ids), function(mi) {
        generate_forecast_draws_centered(
          cell_estimates, calibration_points, model_ids[mi],
          seed = seed + mi, n_draws = n_draws, target_sd = t
        )
      }))
      sens_list[[ti]] <- summarise_provider_draws(dr, model_points) |>
        mutate(target_sd = t)
    }
    sensitivity_tbl <- bind_rows(sens_list)
    sensitivity_agg <- sensitivity_tbl |>
      inner_join(leaders, by = c("race_id", "model_id")) |>
      filter(candidate_id == leader_candidate) |>
      group_by(target_sd) |>
      summarise(
        median_leader_width95_pp = round(median(100 * (q975 - q025)), 2),
        median_leader_sd_pp = round(median(100 * sd_share), 2),
        races_leader_pwin_eq_1 = sum(p_win == 1),
        .groups = "drop"
      )
  }

  # Pseudocount (+0.5 Dirichlet prior) diagnostics: theoretical shrinkage
  # vs observed bias of Dirichlet-only draws, plus the realised Method C
  # bias for the same leader (requirement: check the effect especially for
  # wards with many candidates and small effective sample sizes).
  K_tbl <- crosswalk |> count(race_id, name = "n_candidates")
  leader_cells <- cell_estimates |>
    inner_join(leaders, by = c("race_id", "model_id")) |>
    filter(candidate_id == leader_candidate) |>
    select(race_id, model_id, repeat_id, n_eff,
      leader_cell_share = share
    ) |>
    left_join(K_tbl, by = "race_id") |>
    mutate(
      shrink_pp = pseudocount_shrinkage_pp(
        n_eff, n_candidates,
        leader_cell_share
      ),
      mass_pct = pseudocount_mass_pct(n_eff, n_candidates)
    )
  dirichlet_draws <- bind_rows(lapply(seq_along(model_ids), function(mi) {
    generate_forecast_draws_dirichlet(
      cell_estimates, model_ids[mi],
      seed = seed + 100000L + mi, n_draws = n_draws
    )
  }))
  dirichlet_bias <- forecast_centering_bias(dirichlet_draws, model_points) |>
    select(race_id, model_id,
      observed_dirichlet_bias_pp = leader_bias_pp
    )
  pseudocount_tbl <- leader_cells |>
    group_by(race_id, model_id, n_candidates) |>
    summarise(
      n_eff_min = min(n_eff),
      n_eff_median = median(n_eff),
      theory_shrink_pp_median = median(shrink_pp),
      pseudocount_mass_pct_median = median(mass_pct),
      .groups = "drop"
    ) |>
    left_join(dirichlet_bias, by = c("race_id", "model_id")) |>
    left_join(
      bias_tbl |> select(race_id, model_id,
        observed_centered_bias_pp = leader_bias_pp
      ),
      by = c("race_id", "model_id")
    ) |>
    arrange(observed_dirichlet_bias_pp)

  # -------------------------------------------------------------------------
  # Validation checks (all evaluated before any file is written)
  # -------------------------------------------------------------------------
  checks <- list()
  add_check <- function(label, pass, detail) {
    checks[[length(checks) + 1]] <<- data.frame(
      check = label,
      status = ifelse(isTRUE(pass), "PASS", "FAIL"),
      detail = as.character(detail),
      stringsAsFactors = FALSE
    )
  }

  n_races_out <- n_distinct(draws$race_id)
  n_cand_out <- n_distinct(draws$candidate_id)
  n_cand_grid <- nrow(distinct(crosswalk, race_id, candidate_id))
  n_cells_covered <- responses |>
    distinct(persona_id) |>
    inner_join(personas |> select(persona_id, population_cell_id),
      by = "persona_id"
    ) |>
    distinct(population_cell_id) |>
    nrow()

  if (is_production) {
    add_check(
      "production responses preserved (md5)",
      identical(production_md5, PRODUCTION_LLM_MD5),
      paste0("md5 ", production_md5)
    )
    add_check(
      "production response rows == 36,504",
      nrow(responses) == 36504, nrow(responses)
    )
    add_check(
      "production personas covered == 3,042",
      n_distinct(responses$persona_id) == 3042,
      n_distinct(responses$persona_id)
    )
  }
  add_check(
    "all census population cells covered == 300",
    n_distinct(personas$population_cell_id) == 300 &&
      n_cells_covered == 300,
    paste0(
      "frame ", n_distinct(personas$population_cell_id),
      ", with responses ", n_cells_covered
    )
  )
  add_check(
    "races: outputs == crosswalk",
    n_races_out == n_distinct(crosswalk$race_id),
    paste0(n_races_out, " of ", n_distinct(crosswalk$race_id))
  )
  add_check(
    "candidate grid: 243 candidates / 26 races in crosswalk",
    n_cand_grid == 243 && n_distinct(crosswalk$race_id) == 26,
    paste0(
      n_cand_grid, " candidates / ",
      n_distinct(crosswalk$race_id), " races"
    )
  )
  add_check(
    "summary rows == candidates x providers",
    nrow(summary_tbl) == n_cand_grid * length(model_ids),
    paste0(
      nrow(summary_tbl), " (expect ",
      n_cand_grid * length(model_ids), ")"
    )
  )
  add_check(
    "provider point-estimate rows == candidates x providers",
    nrow(model_points) == n_cand_grid * length(model_ids),
    nrow(model_points)
  )
  add_check(
    "descriptive pooled point rows == candidates",
    nrow(pooled_points) == n_cand_grid, nrow(pooled_points)
  )
  add_check(
    "draw rows == candidates x providers x n_draws",
    nrow(draws) == n_cand_grid * length(model_ids) * n_draws,
    paste0(
      nrow(draws), " (expect ",
      n_cand_grid * length(model_ids) * n_draws, ")"
    )
  )

  sum_dev <- draws |>
    group_by(race_id, model_id, draw_id) |>
    summarise(s = sum(share), .groups = "drop") |>
    summarise(d = max(abs(s - 1))) |>
    pull(d)
  add_check(
    "every draw vector sums to 1",
    sum_dev < 1e-9, sprintf("max |sum-1| = %.3e", sum_dev)
  )

  shares_finite <- !anyNA(draws$share) && !any(is.nan(draws$share))
  add_check(
    "no NA/NaN in draws",
    shares_finite,
    if (shares_finite) "none" else "NA/NaN present"
  )
  add_check(
    "shares within [0, 1]",
    min(draws$share) >= 0 && max(draws$share) <= 1,
    sprintf("[%.6f, %.6f]", min(draws$share), max(draws$share))
  )

  bad_pairs_draws <- draws |>
    distinct(race_id, candidate_id) |>
    anti_join(distinct(crosswalk, race_id, candidate_id),
      by = c("race_id", "candidate_id")
    ) |>
    nrow()
  add_check(
    "draw candidate IDs all valid",
    bad_pairs_draws == 0, paste0(bad_pairs_draws, " invalid pairs")
  )

  pwin_dev <- summary_tbl |>
    group_by(race_id, model_id) |>
    summarise(s = sum(p_win), .groups = "drop") |>
    summarise(d = max(abs(s - 1))) |>
    pull(d)
  add_check(
    "provider-specific p_win sums to 1 per race x provider",
    pwin_dev < 1e-12, sprintf("max |sum-1| = %.3e", pwin_dev)
  )

  cell_dev <- cell_estimates |>
    group_by(race_id, model_id, repeat_id) |>
    summarise(s = sum(share), .groups = "drop") |>
    summarise(d = max(abs(s - 1))) |>
    pull(d)
  add_check(
    "cell estimate shares sum to 1",
    cell_dev < 1e-9, sprintf("max |sum-1| = %.3e", cell_dev)
  )

  add_check(
    "Dirichlet n_eff positive in all cells",
    min(cell_estimates$n_eff) > 0,
    sprintf("min n_eff = %.1f", min(cell_estimates$n_eff))
  )

  if (!is.null(sensitivity_tbl)) {
    base_sens <- sensitivity_tbl |> filter(target_sd == !!target_sd)
    cmp <- base_sens |>
      inner_join(
        summary_tbl |> select(race_id, model_id, candidate_id,
          p_win_ref = p_win, mean_ref = mean_share
        ),
        by = c("race_id", "model_id", "candidate_id")
      )
    sens_dev <- max(
      abs(cmp$p_win - cmp$p_win_ref),
      abs(cmp$mean_share - cmp$mean_ref)
    )
    add_check(
      "sensitivity row at target_sd reproduces production summary",
      sens_dev == 0, sprintf("max abs diff = %.3e", sens_dev)
    )
    add_check(
      "sensitivity grid complete (0.02 / 0.04 / 0.06)",
      setequal(
        unique(sensitivity_tbl$target_sd),
        c(0.02, 0.04, 0.06)
      ),
      paste(sort(unique(sensitivity_tbl$target_sd)), collapse = ", ")
    )
  }

  add_check(
    "max leader-centring bias is reported (not assumed zero)",
    is.finite(max_bias_pp) && max_bias_pp >= 0,
    sprintf("max |leader bias| = %.2f pp", max_bias_pp)
  )
  add_check(
    "max leader-centring bias within 10pp sanity bound",
    max_bias_pp <= 10,
    sprintf("%.2f pp", max_bias_pp)
  )

  replay <- draw_fun(model_ids[1], seed + 1)
  replay_stored <- draws |> filter(model_id == model_ids[1])
  replay_ok <- isTRUE(all.equal(replay, as.data.frame(replay_stored),
    check.attributes = FALSE
  ))
  add_check(
    "fixed seed reproduces byte-identical draws",
    replay_ok, paste0("provider ", model_ids[1])
  )

  checks_tbl <- bind_rows(checks)
  n_fail <- sum(checks_tbl$status == "FAIL")

  # -------------------------------------------------------------------------
  # Validation report (deterministic: no timestamps, so reruns recompute
  # the identical file and are kept, never silently overwritten)
  # -------------------------------------------------------------------------
  sens_lines <- if (!is.null(sensitivity_agg)) {
    c(
      "",
      "| target SD | median leader 95% width | median leader sd | leader p_win = 1 |",
      "|---|---|---|---|",
      sprintf(
        "| %.2f | %.2f pp | %.2f pp | %d of %d |",
        sensitivity_agg$target_sd,
        sensitivity_agg$median_leader_width95_pp,
        sensitivity_agg$median_leader_sd_pp,
        sensitivity_agg$races_leader_pwin_eq_1,
        nrow(leaders)
      )
    )
  } else {
    c("", paste0(
      "Sensitivity analysis not run for method '", uncertainty,
      "' (Method C only)."
    ))
  }

  worst_pseudocount <- head(pseudocount_tbl, 5)
  pseudo_lines <- c(
    "",
    "| race | provider | K | n_eff (min) | pseudocount mass | theory shrink | observed Dirichlet bias | observed Method C bias |",
    "|---|---|---|---|---|---|---|---|",
    sprintf(
      "| %s | %s | %d | %.1f | %.2f%% | %.2f pp | %.2f pp | %.2f pp |",
      worst_pseudocount$race_id, worst_pseudocount$model_id,
      worst_pseudocount$n_candidates, worst_pseudocount$n_eff_min,
      worst_pseudocount$pseudocount_mass_pct_median,
      worst_pseudocount$theory_shrink_pp_median,
      worst_pseudocount$observed_dirichlet_bias_pp,
      worst_pseudocount$observed_centered_bias_pp
    )
  )

  worst_bias <- bias_tbl |> slice_max(abs(leader_bias_pp), n = 1)

  report_lines <- c(
    "# Task 6C — Final forecast validation report",
    "",
    "## Inputs and method",
    "",
    paste0(
      "- Response file: `", llm_path, "`",
      if (is_production) paste0(" (md5 `", production_md5, "`)") else ""
    ),
    paste0(
      "- Rows: ", nrow(responses), " | personas: ",
      n_distinct(responses$persona_id), " | providers: ",
      paste(model_ids, collapse = ", "), " | repeats: ", n_repeats
    ),
    paste0(
      "- Uncertainty method: **", uncertainty, "**",
      if (uncertainty == "centered") {
        paste0(" (perturbation target SD = ", target_sd, ")")
      } else {
        ""
      }
    ),
    paste0(
      "- Draws per race x provider: ", n_draws,
      "; base seed: ", seed, " (provider m uses seed + m; sensitivity ",
      "uses the same seeds = common random numbers)"
    ),
    "",
    "Variance sources (explicitly distinguished):",
    "",
    "1. **LLM response variability** — each draw resamples one of the",
    "   provider's 3 repeat cells (within-provider; provider disagreement",
    "   is reported separately, never averaged away).",
    "2. **Dirichlet sampling uncertainty** — share ~",
    "   Dirichlet(n_eff * share + 0.5) with the Kish effective sample size.",
    "3. **Assumed forecast perturbation** (Method C) — multiplicative",
    "   logistic-normal s_k <- s_k * exp(sigma * eps_k), eps ~ N(0,1),",
    "   renormalised; sigma calibrated per race so this layer alone gives",
    "   the leader an sd of the target SD above.",
    "4. **Real election uncertainty — NOT modelled.** Intervals and",
    "   win frequencies are conditional on the LLM responses and the",
    "   assumed perturbation scale; they are illustrative simulation",
    "   frequencies, not calibrated probabilities for a real election.",
    "",
    "## Output shapes",
    "",
    paste0("- `cell_estimates.parquet`: ", nrow(cell_estimates), " rows"),
    paste0(
      "- `candidate_point_estimates.parquet`: ", nrow(model_points),
      " rows (provider-specific, equal weight over repeats)"
    ),
    paste0(
      "- `pooled_point_estimates_descriptive.parquet`: ",
      nrow(pooled_points),
      " rows (labelled descriptive, equal weight over 6 cells)"
    ),
    paste0(
      "- `forecast_draws_", uncertainty, ".parquet`: ", nrow(draws),
      " rows"
    ),
    paste0(
      "- `forecast_summary_", uncertainty, ".parquet`: ",
      nrow(summary_tbl), " rows"
    ),
    paste0(
      "- `centering_bias_", uncertainty, ".parquet`: ",
      nrow(bias_tbl), " rows"
    ),
    if (!is.null(sensitivity_tbl)) {
      paste0(
        "- `sensitivity_target_sd.parquet`: ", nrow(sensitivity_tbl),
        " rows (3 target SDs)"
      )
    },
    paste0(
      "- `pseudocount_effect.parquet`: ", nrow(pseudocount_tbl),
      " rows"
    ),
    "",
    "## Validation checks",
    "",
    "| check | status | detail |",
    "|---|---|---|",
    sprintf(
      "| %s | %s | %s |", checks_tbl$check, checks_tbl$status,
      checks_tbl$detail
    ),
    "",
    "## Leader-centring bias (reported, not assumed zero)",
    "",
    paste0(
      "Method C is only **approximately** centre-preserving. The",
      " realised maximum |leader bias| is **",
      sprintf("%.2f pp", max_bias_pp), "**",
      " (worst: ", worst_bias$race_id, " / ", worst_bias$model_id,
      ")."
    ),
    paste0(
      "For reference, the original additive-noise construction (A)",
      " showed up to ~38 pp leader bias on the mayoral race in the",
      " Task 6B comparison."
    ),
    "",
    "## Dirichlet +0.5 pseudocount effect (5 worst races by observed bias)",
    "",
    pseudo_lines,
    "",
    "## Method C sensitivity to the perturbation target SD",
    "",
    sens_lines,
    "",
    "## Limitations",
    "",
    "- Uncertainty is **not calibrated** to historical election or",
    "  polling error; p_win values are simulation frequencies under the",
    "  stated model, not real winning probabilities.",
    "- The Dirichlet +0.5 prior shrinks low-n_eff, many-candidate wards",
    "  toward uniform (see table above); point estimates are unchanged,",
    "  so this shrinkage affects draws only.",
    "- Provider disagreement dominates method differences in several",
    "  races; provider-specific forecasts must be read separately.",
    "- The mayoral race is effectively degenerate in the source responses",
    "  (mode collapse measured in Task 5/6A); no uncertainty method can",
    "  honestly manufacture competitiveness from it.",
    "- Undecided responses are excluded from estimation (decided-share",
    "  target); no nonresponse adjustment is applied."
  )

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  report_path <- file.path(out_dir, "validation_report.md")
  write_forecast_lines(report_lines, report_path, overwrite = overwrite)

  if (n_fail > 0) {
    stop(
      "Validation FAILED (", n_fail, " check(s)); report written to ",
      report_path, "\n",
      paste0("  - ", checks_tbl$check[checks_tbl$status == "FAIL"],
        ": ", checks_tbl$detail[checks_tbl$status == "FAIL"],
        collapse = "\n"
      )
    )
  }

  # Method-independent tables recompute identically on reruns -> kept.
  write_forecast_output(cell_estimates,
    file.path(out_dir, "cell_estimates.parquet"),
    overwrite = overwrite, identical_ok = TRUE
  )
  write_forecast_output(model_points,
    file.path(out_dir, "candidate_point_estimates.parquet"),
    overwrite = overwrite, identical_ok = TRUE
  )
  write_forecast_output(pooled_points,
    file.path(out_dir, "pooled_point_estimates_descriptive.parquet"),
    overwrite = overwrite, identical_ok = TRUE
  )
  # Method-tagged outputs: distinct files per method, never silent overwrites.
  write_forecast_output(draws,
    file.path(out_dir, sprintf("forecast_draws_%s.parquet", uncertainty)),
    overwrite = overwrite
  )
  write_forecast_output(summary_tbl,
    file.path(out_dir, sprintf("forecast_summary_%s.parquet", uncertainty)),
    overwrite = overwrite
  )
  write_forecast_output(bias_tbl,
    file.path(out_dir, sprintf("centering_bias_%s.parquet", uncertainty)),
    overwrite = overwrite
  )
  if (!is.null(sensitivity_tbl)) {
    write_forecast_output(sensitivity_tbl,
      file.path(out_dir, "sensitivity_target_sd.parquet"),
      overwrite = overwrite
    )
  }
  write_forecast_output(pseudocount_tbl,
    file.path(out_dir, "pseudocount_effect.parquet"),
    overwrite = overwrite, identical_ok = TRUE
  )

  message(
    "Forecast (method = ", uncertainty, ") written to ", out_dir, "/\n",
    "  cell estimates:     ", nrow(cell_estimates), "\n",
    "  provider points:    ", nrow(model_points), "\n",
    "  pooled (descriptive): ", nrow(pooled_points), "\n",
    "  draw rows:          ", nrow(draws), "\n",
    "  summary rows:       ", nrow(summary_tbl), "\n",
    if (!is.null(sensitivity_tbl)) {
      paste0("  sensitivity rows:   ", nrow(sensitivity_tbl), "\n")
    },
    "  validation checks:  ", sum(checks_tbl$status == "PASS"), " PASS / ",
    n_fail, " FAIL\n",
    "  max |leader centring bias|: ", sprintf("%.2f pp", max_bias_pp)
  )
  invisible(list(
    cell_estimates = cell_estimates,
    model_points   = model_points,
    pooled_points  = pooled_points,
    draws          = draws,
    summary        = summary_tbl,
    centering_bias = bias_tbl,
    sensitivity    = sensitivity_tbl,
    pseudocount    = pseudocount_tbl,
    checks         = checks_tbl
  ))
}

# Run when executed as a script (Rscript) rather than sourced in tests.
# Usage: Rscript R/10_llm_poststratify.R [llm_path] [uncertainty]
if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  run_llm_poststratify(
    llm_path    = if (length(args) >= 1) args[1] else PRODUCTION_LLM_PATH,
    uncertainty = if (length(args) >= 2) args[2] else "centered"
  )
}
