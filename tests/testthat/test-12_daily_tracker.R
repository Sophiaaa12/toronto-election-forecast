# test-12_daily_tracker.R
#
# Daily tracker (R/11_daily_panel.R, R/12_daily_forecast.R):
#   - the fixed panel covers all 300 cells and preserves ward weights;
#   - the panel is reproducible;
#   - one synthetic day flows through post-stratification + Method C
#     draws into the summary, stats and history files, with failures
#     retained and win frequencies summing to one.

library(testthat)
library(dplyr)
library(nanoparquet)

find_project_root <- function(path = getwd()) {
  dir <- normalizePath(path)
  repeat {
    if (file.exists(file.path(dir, "toronto-election-forecast.Rproj"))) return(dir)
    parent <- dirname(dir)
    if (identical(parent, dir)) stop("Could not find project root")
    dir <- parent
  }
}
old_wd <- setwd(find_project_root())
on.exit(setwd(old_wd), add = TRUE)

source(file.path("R", "11_daily_panel.R"))
source(file.path("R", "12_daily_forecast.R"))

personas  <- read_parquet(file.path("processed", "simulated", "simulated_personas.parquet"))
crosswalk <- read_parquet(file.path("processed", "simulated", "candidate_crosswalk.parquet"))

test_that("panel covers every cell and preserves ward and cell weights", {
  panel <- build_daily_panel(personas, per_cell = 4)
  expect_equal(nrow(panel), 1200)
  expect_equal(n_distinct(panel$population_cell_id), 300)
  expect_true(all(table(panel$population_cell_id) == 4))
  expect_equal(sum(panel$sampling_weight), 1, tolerance = 1e-12)
  ward_full  <- personas |> group_by(ward) |> summarise(w = sum(sampling_weight))
  ward_panel <- panel |> group_by(ward) |> summarise(w = sum(sampling_weight))
  expect_equal(ward_panel$w, ward_full$w, tolerance = 1e-12)
  expect_true(all(panel$persona_id %in% personas$persona_id))
})

test_that("panel is reproducible and rejects oversized cells", {
  expect_identical(build_daily_panel(personas), build_daily_panel(personas))
  expect_error(build_daily_panel(personas, per_cell = 6), "exceeds the smallest cell")
})

test_that("one synthetic day produces summary, stats and history", {
  daily_dir <- tempfile("daily_")
  dir.create(daily_dir)
  panel <- build_daily_panel(personas, per_cell = 1)
  write_parquet(panel, file.path(daily_dir, "panel_personas.parquet"))

  set.seed(7)
  models <- c("google/gemini-2.5-flash-lite", "openai/gpt-4o-mini")
  day <- "2026-10-21"
  dir.create(file.path(daily_dir, "responses", day), recursive = TRUE)
  for (m in models) {
    resp <- bind_rows(
      panel |> mutate(race_id = "mayor"),
      panel |> mutate(race_id = sprintf("ward_%02d_councillor", ward))
    ) |>
      rowwise() |>
      mutate(candidate_id = sample(crosswalk$candidate_id[crosswalk$race_id == race_id], 1)) |>
      ungroup() |>
      mutate(response_status = "valid_choice")
    resp$response_status[1:5] <- "timeout"
    resp$candidate_id[1:5] <- NA_character_
    resp <- resp |>
      transmute(persona_id, ward, race_id, candidate_id,
                provider_id = sub("/.*", "", m), model_id = m, repeat_id = 1L,
                response_status, input_tokens = 1000L, cached_tokens_reported = 0L,
                output_tokens = 20L, cost_usd_actual = 1e-4)
    write_parquet(resp, file.path(daily_dir, "responses", day,
                                  paste0(sub("/.*", "", m), ".parquet")))
  }

  out <- suppressMessages(run_daily_forecast(day, daily_dir = daily_dir, n_draws = 50))
  s <- out$summary
  expect_equal(n_distinct(s$race_id), 26)
  expect_setequal(unique(s$model_id), models)
  expect_equal(nrow(s), nrow(crosswalk) * 2)
  pw <- s |> group_by(race_id, model_id) |> summarise(t = sum(p_win), .groups = "drop")
  expect_true(all(abs(pw$t - 1) < 1e-9))
  ps <- s |> group_by(race_id, model_id) |> summarise(t = sum(point_share), .groups = "drop")
  expect_true(all(abs(ps$t - 1) < 1e-9))
  expect_true(all(s$poll_date == day))

  expect_equal(out$stats$failed, c(5, 5))
  expect_equal(out$stats$requests, c(600, 600))
  hist <- readr::read_csv(file.path(daily_dir, "history.csv"), show_col_types = FALSE)
  expect_equal(nrow(hist), nrow(s))
  expect_false(anyNA(hist$display_name))
  expect_true(file.exists(file.path(daily_dir, "stats_history.csv")))
})
