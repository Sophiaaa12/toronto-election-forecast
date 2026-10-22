# R/12_daily_forecast.R
#
# Daily tracker: post-stratify one day's panel responses and append the
# result to the running history.
#
# The statistics are the production ones, unchanged:
#   - poststratify_responses() with the daily panel's design weights;
#   - provider-specific point shares (build_model_point_estimates);
#   - Method C draws (generate_forecast_draws_centered, target SD 4pp)
#     giving 95% simulation intervals and win frequencies per provider.
# Each day has ONE repeat per persona x race x provider, so the draws'
# repeat-resampling layer is degenerate; the Dirichlet and Method C
# layers are unchanged.
#
# Usage:
#   Rscript R/12_daily_forecast.R 2026-10-21
#
# Inputs:
#   processed/daily/responses/<date>/*.parquet   (one file per provider)
#   processed/daily/panel_personas.parquet       (R/11_daily_panel.R)
#   processed/simulated/candidate_crosswalk.parquet
#   processed/daily/news/<date>.json
#
# Outputs:
#   processed/daily/summary/<date>.parquet   candidate shares per provider
#   processed/daily/stats/<date>.csv         status counts, tokens, cost
#   processed/daily/history.csv              all days, all candidates
#   processed/daily/stats_history.csv        all days, per provider

source(file.path("R", "10_llm_poststratify.R"))

DAILY_DIR <- file.path("processed", "daily")
DAILY_DRAWS <- 500L

run_daily_forecast <- function(poll_date,
                               daily_dir = DAILY_DIR,
                               crosswalk_path = file.path(
                                 "processed", "simulated",
                                 "candidate_crosswalk.parquet"
                               ),
                               n_draws = DAILY_DRAWS,
                               seed = SIM_SEEDS$forecast) {
  stopifnot(grepl("^\\d{4}-\\d{2}-\\d{2}$", poll_date))
  resp_files <- list.files(file.path(daily_dir, "responses", poll_date),
    pattern = "\\.parquet$", full.names = TRUE
  )
  if (length(resp_files) == 0) stop("no daily responses for ", poll_date)

  responses <- bind_rows(lapply(resp_files, read_parquet))
  personas <- read_parquet(file.path(daily_dir, "panel_personas.parquet"))
  crosswalk <- read_parquet(crosswalk_path)

  problems <- c(
    validate_llm_responses(responses, crosswalk),
    validate_llm_personas(responses, personas)
  )
  if (length(problems) > 0) {
    stop(
      "daily response validation failed:\n",
      paste0("  - ", problems, collapse = "\n")
    )
  }

  model_ids <- sort(unique(responses$model_id))
  post <- poststratify_responses(
    responses = responses, personas = personas, crosswalk = crosswalk,
    model_ids = model_ids, n_repeats = max(responses$repeat_id)
  )
  # A provider can end up with no valid answer in a race (e.g. every
  # request in that race failed); such cells carry no information.
  cells <- post$cells |> filter(!is.na(n_eff), n_eff > 0)

  model_points <- build_model_point_estimates(cells)
  pooled <- build_pooled_point_estimates(cells, post$point) |>
    transmute(race_id, candidate_id, point_share = pooled_equal_weight_share)

  draws <- bind_rows(lapply(seq_along(model_ids), function(mi) {
    if (!any(cells$model_id == model_ids[mi])) {
      return(NULL)
    }
    generate_forecast_draws_centered(cells, pooled, model_ids[mi],
      seed = seed + mi, n_draws = n_draws
    )
  }))
  n_eff_tbl <- cells |> distinct(race_id, model_id, n_eff)
  summary_tbl <- summarise_provider_draws(draws, model_points) |>
    left_join(n_eff_tbl, by = c("race_id", "model_id")) |>
    transmute(
      poll_date, race_id, model_id, candidate_id,
      point_share, n_valid, n_eff, mean_share, q025, q975, p_win
    )

  pw <- summary_tbl |>
    group_by(race_id, model_id) |>
    summarise(s = sum(p_win), .groups = "drop")
  stopifnot(max(abs(pw$s - 1)) < 1e-9, !anyNA(summary_tbl$point_share))

  news_path <- file.path(daily_dir, "news", paste0(poll_date, ".json"))
  n_news <- if (file.exists(news_path)) {
    length(jsonlite::fromJSON(news_path)$items$title)
  } else {
    NA_integer_
  }

  stats_tbl <- responses |>
    group_by(model_id) |>
    summarise(
      poll_date = poll_date,
      requests = n(),
      personas = n_distinct(persona_id),
      valid_choice = sum(response_status == "valid_choice"),
      undecided = sum(response_status == "undecided"),
      not_voting = sum(response_status == "not_voting"),
      failed = sum(!response_status %in% LLM_MODEL_STATUSES),
      input_tokens = sum(input_tokens, na.rm = TRUE),
      cached_tokens = sum(cached_tokens_reported, na.rm = TRUE),
      output_tokens = sum(output_tokens, na.rm = TRUE),
      cost_usd = round(sum(cost_usd_actual, na.rm = TRUE), 6),
      news_items = n_news,
      .groups = "drop"
    ) |>
    relocate(poll_date)

  dir.create(file.path(daily_dir, "summary"), showWarnings = FALSE, recursive = TRUE)
  dir.create(file.path(daily_dir, "stats"), showWarnings = FALSE, recursive = TRUE)
  write_parquet(summary_tbl, file.path(daily_dir, "summary", paste0(poll_date, ".parquet")))
  readr::write_csv(stats_tbl, file.path(daily_dir, "stats", paste0(poll_date, ".csv")))

  rebuild_daily_history(daily_dir, crosswalk)
  message(
    "Daily forecast ", poll_date, ": ", nrow(responses), " responses, ",
    length(model_ids), " providers, ", n_distinct(summary_tbl$race_id),
    " races; cost $", sum(stats_tbl$cost_usd)
  )
  invisible(list(summary = summary_tbl, stats = stats_tbl))
}

rebuild_daily_history <- function(daily_dir = DAILY_DIR, crosswalk) {
  sfiles <- sort(list.files(file.path(daily_dir, "summary"),
    pattern = "\\.parquet$", full.names = TRUE
  ))
  history <- bind_rows(lapply(sfiles, read_parquet)) |>
    left_join(
      crosswalk |> select(race_id, candidate_id, ballot_name,
        display_name,
        incumbent = incumbent_name_match
      ),
      by = c("race_id", "candidate_id")
    ) |>
    arrange(poll_date, race_id, model_id, candidate_id)
  readr::write_csv(history, file.path(daily_dir, "history.csv"))

  tfiles <- sort(list.files(file.path(daily_dir, "stats"),
    pattern = "\\.csv$", full.names = TRUE
  ))
  stats <- bind_rows(lapply(tfiles, readr::read_csv,
    show_col_types = FALSE,
    col_types = readr::cols(poll_date = "c")
  ))
  readr::write_csv(stats, file.path(daily_dir, "stats_history.csv"))
  invisible(history)
}

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) < 1) stop("usage: Rscript R/12_daily_forecast.R YYYY-MM-DD")
  run_daily_forecast(args[1])
}
