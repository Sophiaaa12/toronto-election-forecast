# test-09_poststratify_forecast.R
#
# Validates demographic post-stratification and the Monte Carlo forecast
# distributions produced by R/09_poststratify_forecast.R.
#
# Coverage (required test categories):
#   - Candidate vote shares sum to one among valid candidate choices
#   - Vote shares between zero and one
#   - Citywide mayoral weights reflect ward populations (mayoral
#     aggregation is population-weighted, not equal-ward)
#   - Forecast draws contain multiple repetitions
#   - Forecast outputs are reproducible with fixed seeds
#   - No invalid candidate IDs in forecast outputs

library(testthat)
library(dplyr)
library(nanoparquet)

find_project_root <- function(path = getwd()) {
  dir <- normalizePath(path)
  repeat {
    if (file.exists(file.path(dir, "toronto-election-forecast.Rproj"))) {
      return(dir)
    }
    parent <- dirname(dir)
    if (identical(parent, dir)) {
      stop("Could not locate the project root directory")
    }
    dir <- parent
  }
}

project_root <- find_project_root()
withr::local_dir(project_root)

# Rebuild the full simulated pipeline from source
source(file.path("R", "07_simulate_personas.R"))
source(file.path("R", "08_simulate_llm_responses.R"))
source(file.path("R", "09_poststratify_forecast.R"))

personas <- read_parquet(
  file.path("processed", "simulated", "simulated_personas.parquet")
)
responses <- read_parquet(
  file.path("processed", "simulated", "simulated_responses.parquet")
)
crosswalk <- read_parquet(
  file.path("processed", "simulated", "candidate_crosswalk.parquet")
)
draws <- read_parquet(
  file.path("processed", "simulated", "simulated_forecast_draws.parquet")
)
summary_tbl <- read_parquet(
  file.path("processed", "simulated", "simulated_forecast_summary.parquet")
)

test_that("forecast outputs have the required schema", {
  expect_true(all(
    c(
      "race_id", "candidate_id", "draw_id", "source_model_id",
      "source_repeat_id", "share"
    ) %in% names(draws)
  ))
  expect_true(all(
    c(
      "race_id", "candidate_id", "mean_share", "sd_share", "q025",
      "q50", "q975", "p_win", "point_share"
    ) %in% names(summary_tbl)
  ))
})

test_that("candidate vote shares sum to one among valid candidate choices", {
  # Pooled point estimates: shares sum to 1 within each race.
  pts <- summary_tbl |>
    group_by(race_id) |>
    summarise(s = sum(point_share), .groups = "drop")
  expect_equal(nrow(pts), 26)
  expect_equal(pts$s, rep(1, 26), tolerance = 1e-9)

  # Every individual Monte Carlo draw also sums to 1 within a race.
  draw_sums <- draws |>
    group_by(race_id, draw_id) |>
    summarise(s = sum(share), .groups = "drop")
  expect_true(all(abs(draw_sums$s - 1) < 1e-9))
})

test_that("vote shares are between zero and one", {
  expect_true(all(draws$share >= 0 & draws$share <= 1))
  expect_true(all(summary_tbl$point_share >= 0 & summary_tbl$point_share <= 1))
  expect_true(all(summary_tbl$mean_share >= 0 & summary_tbl$mean_share <= 1))
  expect_true(all(summary_tbl$q025 >= 0 & summary_tbl$q975 <= 1))
  expect_true(all(summary_tbl$p_win >= 0 & summary_tbl$p_win <= 1))
})

test_that("every race and candidate appears in the forecast", {
  expect_equal(n_distinct(draws$race_id), 26)
  expect_equal(nrow(summary_tbl), nrow(crosswalk))

  # No invalid candidate IDs in the forecast outputs.
  expect_true(all(summary_tbl$candidate_id %in% crosswalk$candidate_id))
  expect_true(all(draws$candidate_id %in% crosswalk$candidate_id))

  # Candidate-to-race mapping is consistent with the crosswalk.
  chk <- summary_tbl |>
    select(race_id, candidate_id) |>
    inner_join(
      crosswalk |> select(candidate_id, true_race = race_id),
      by = "candidate_id"
    )
  expect_true(all(chk$race_id == chk$true_race))
})

test_that("mayoral aggregation is population-weighted, not equal-ward", {
  # The mayoral point estimate pools ALL personas with citywide design
  # weights, so wards enter in proportion to their 20+ population. We
  # verify this is not an equal-ward average by recomputing the top
  # mayoral candidate's share under both schemes and confirming they
  # differ, while the design-weighted recomputation reproduces the
  # reported point estimate exactly.
  valid_mayor <- responses |>
    filter(race_id == "mayor", response_status == "valid_choice") |>
    left_join(
      personas |> select(persona_id, sampling_weight),
      by = "persona_id"
    )

  # Design-weighted (what the pipeline computes)
  design_share <- valid_mayor |>
    group_by(candidate_id) |>
    summarise(w = sum(sampling_weight), .groups = "drop") |>
    mutate(share = w / sum(w)) |>
    arrange(desc(share))

  reported <- summary_tbl |>
    filter(race_id == "mayor") |>
    arrange(desc(point_share))

  expect_equal(design_share$candidate_id[1], reported$candidate_id[1])
  expect_equal(design_share$share[1], reported$point_share[1],
    tolerance = 1e-9
  )

  # Equal-ward average (WRONG scheme) must give a different top-share
  # value, confirming wards are not treated as equally sized.
  equal_ward_share <- valid_mayor |>
    group_by(ward, candidate_id) |>
    summarise(sw = sum(sampling_weight), .groups = "drop") |>
    group_by(ward) |>
    mutate(share_w = sw / sum(sw)) |>
    ungroup() |>
    group_by(candidate_id) |>
    summarise(share = mean(share_w), .groups = "drop") |>
    arrange(desc(share))

  # The two weighting schemes are genuinely different estimators.
  expect_false(
    isTRUE(all.equal(design_share$share[1], equal_ward_share$share[1],
      tolerance = 1e-6
    ))
  )
})

test_that("forecast draws contain multiple repetitions and sources", {
  expect_equal(n_distinct(draws$draw_id), 500)
  expect_gte(n_distinct(draws$draw_id), 2)
  expect_equal(n_distinct(draws$source_model_id), 2)
  expect_equal(sort(unique(draws$source_repeat_id)), 1:3)

  # Each race has the full 500 draws for every candidate.
  per_cand <- draws |>
    group_by(race_id, candidate_id) |>
    summarise(n = n_distinct(draw_id), .groups = "drop")
  expect_true(all(per_cand$n == 500))
})

test_that("forecast outputs are reproducible with fixed seeds", {
  # Re-run the post-stratification + draw generation with the same fixed
  # seed and confirm the outputs are byte-identical.
  source(file.path("R", "09_poststratify_forecast.R"))
  draws2 <- read_parquet(
    file.path("processed", "simulated", "simulated_forecast_draws.parquet")
  )
  summary2 <- read_parquet(
    file.path("processed", "simulated", "simulated_forecast_summary.parquet")
  )

  expect_equal(as.data.frame(draws), as.data.frame(draws2))
  expect_equal(as.data.frame(summary_tbl), as.data.frame(summary2))
})

test_that("uncertainty is decomposed across model, repeat, and forecast noise", {
  # Draws resample both providers and all three repeats, and the
  # post-Dirichlet Gaussian noise means a candidate's draw distribution
  # is not degenerate even at a fixed (model, repeat) cell. We check the
  # forecast intervals are non-degenerate (sd > 0) for candidates with
  # non-trivial support.
  active <- summary_tbl |> filter(point_share > 0.01)
  expect_gt(nrow(active), 0)
  expect_true(all(active$sd_share > 0))
  expect_true(all(active$q975 > active$q025))
})
