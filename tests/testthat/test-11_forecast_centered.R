# test-11_forecast_centered.R
#
# Task 6C tests for the revised forecast uncertainty pipeline
# (additions to R/simulation_helpers.R + updated R/10_llm_poststratify.R).
#
# Coverage (Task 6C requirement 12):
#   - draw vectors sum to 1
#   - no NA or NaN in draws
#   - candidate IDs in draws are valid crosswalk members
#   - zero-support candidates stay exactly zero under the multiplicative
#     layer (and gain far less mass than under the additive-noise method)
#   - fixed seeds reproduce identical draws
#   - expected output row counts
#   - provider-specific p_win sums to 1 per race x provider
#   - maximum leader-centring bias is REPORTED (finite, >= 0), never
#     silently assumed zero (Method C is only approximately
#     centre-preserving)
#   - the ORIGINAL generate_forecast_draws() keeps its schema/behaviour
#   - sigma calibration reaches the target sd

library(testthat)
library(dplyr)

find_project_root <- function(path = getwd()) {
  dir <- normalizePath(path)
  repeat {
    if (file.exists(file.path(dir, "toronto-election-forecast.Rproj"))) {
      return(dir)
    }
    parent <- dirname(dir)
    if (identical(parent, dir)) stop("Could not locate the project root directory")
    dir <- parent
  }
}
project_root <- find_project_root()
old_wd <- setwd(project_root)
on.exit(setwd(old_wd), add = TRUE)

source(file.path("R", "10_llm_poststratify.R"))

# ---------------------------------------------------------------------------
# Fixture: 2 races x 2 providers x 3 repeats of cell estimates.
# mayor has K = 3 with MAYOR-003 exact zero everywhere (zero-support);
# ward has K = 2. Shares sum to 1 within every cell.
# ---------------------------------------------------------------------------
make_cells <- function() {
  base <- tidyr::expand_grid(
    race_id   = c("mayor", "ward_01_councillor"),
    model_id  = c("prov-a/m", "prov-b/m"),
    repeat_id = 1:3
  )
  rows <- lapply(seq_len(nrow(base)), function(i) {
    b <- base[i, ]
    if (b$race_id == "mayor") {
      cands  <- c("MAYOR-001", "MAYOR-002", "MAYOR-003")
      a      <- 0.60 + 0.05 * (b$repeat_id - 1) +
        ifelse(b$model_id == "prov-a/m", 0.05, -0.05)
      shares <- c(a, 1 - a, 0)     # MAYOR-003 exact zero in every cell
      n_eff  <- 200
    } else {
      cands  <- c("W01-C01", "W01-C02")
      a      <- 0.55 + 0.02 * (b$repeat_id - 1) +
        ifelse(b$model_id == "prov-a/m", 0.05, -0.05)
      shares <- c(a, 1 - a)
      n_eff  <- 100
    }
    data.frame(
      race_id          = b$race_id,
      model_id         = b$model_id,
      repeat_id        = b$repeat_id,
      candidate_id     = cands,
      weighted_support = shares,
      n_valid          = 60L,
      sum_w            = 1,
      sum_w2           = 0.01,
      n_eff             = n_eff,
      share            = shares,
      stringsAsFactors = FALSE
    )
  })
  dplyr::bind_rows(rows)
}

cells <- make_cells()
model_points <- build_model_point_estimates(cells)
calib_points <- cells |>
  group_by(race_id, candidate_id) |>
  summarise(point_share = mean(share), .groups = "drop")

N_DRAWS_SMALL <- 60L

# ---------------------------------------------------------------------------
# Draw-level invariants for all three methods
# ---------------------------------------------------------------------------
test_that("draw vectors sum to 1 and shares stay in [0, 1] (all methods)", {
  for (m in c("centered", "dirichlet", "existing")) {
    dr <- switch(
      m,
      centered  = generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                                   seed = 11, n_draws = N_DRAWS_SMALL),
      dirichlet = generate_forecast_draws_dirichlet(cells, "prov-a/m",
                                                    seed = 11, n_draws = N_DRAWS_SMALL),
      existing  = generate_forecast_draws_existing(cells, "prov-a/m",
                                                   seed = 11, n_draws = N_DRAWS_SMALL)
    )
    sums <- dr |>
      group_by(race_id, draw_id) |>
      summarise(s = sum(share), .groups = "drop")
    expect_true(all(abs(sums$s - 1) < 1e-9), info = m)
    expect_true(min(dr$share) >= 0 && max(dr$share) <= 1, info = m)
  }
})

test_that("no NA or NaN appears in draws", {
  dr <- generate_forecast_draws_centered(cells, calib_points, "prov-b/m",
                                         seed = 22, n_draws = N_DRAWS_SMALL)
  expect_false(anyNA(dr$share))
  expect_false(any(is.nan(dr$share)))
  expect_false(anyNA(dr$source_repeat_id))
})

test_that("draw candidate IDs are valid members of the race grid", {
  valid <- distinct(cells, race_id, candidate_id)
  dr <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                         seed = 33, n_draws = N_DRAWS_SMALL)
  bad <- distinct(dr, race_id, candidate_id) |>
    anti_join(valid, by = c("race_id", "candidate_id"))
  expect_equal(nrow(bad), 0)
  expect_setequal(unique(dr$model_id), "prov-a/m")  # provider-specific
})

# ---------------------------------------------------------------------------
# Zero-support behaviour of the multiplicative layer (Method C)
# ---------------------------------------------------------------------------
test_that("multiplicative layer keeps exact zeros exactly zero", {
  s <- c(0.5, 0.3, 0.2, 0)
  out <- apply_multiplicative_layer(s, sigma = 0.5)
  expect_identical(out[4], 0)
  expect_true(all(out[1:3] > 0))
  expect_equal(sum(out), 1)
  # random eps path too
  out2 <- apply_multiplicative_layer(s, sigma = 0.2, eps = c(1, -2, 0.5, 99))
  expect_identical(out2[4], 0)
})

test_that("zero-support candidate gains far less mass under centered than existing", {
  dr_c <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                           seed = 44, n_draws = 400)
  dr_e <- generate_forecast_draws_existing(cells, "prov-a/m",
                                           seed = 44, n_draws = 400)
  zero_c <- dr_c |> filter(candidate_id == "MAYOR-003") |> summarise(m = mean(share)) |> pull(m)
  zero_e <- dr_e |> filter(candidate_id == "MAYOR-003") |> summarise(m = mean(share)) |> pull(m)
  # Dirichlet pseudocount mass ~ 0.5/(200 + 1.5) ~= 0.25% for centered;
  # the additive 3pp noise injects an order of magnitude more.
  expect_true(zero_c < zero_e)
  expect_true(zero_c < 0.01)
})

# ---------------------------------------------------------------------------
# Reproducibility and row counts
# ---------------------------------------------------------------------------
test_that("fixed seeds reproduce identical draws; different seeds differ", {
  a1 <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                         seed = 55, n_draws = N_DRAWS_SMALL)
  a2 <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                         seed = 55, n_draws = N_DRAWS_SMALL)
  a3 <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                         seed = 56, n_draws = N_DRAWS_SMALL)
  expect_identical(a1, a2)
  expect_false(isTRUE(all.equal(a1, a3)))
  # calibration itself is independently reproducible (fixed calibration seed)
  s1 <- calibrate_forecast_sigma(c(0.6, 0.3, 0.1), target_sd = 0.04, n_pilot = 5000)
  s2 <- calibrate_forecast_sigma(c(0.6, 0.3, 0.1), target_sd = 0.04, n_pilot = 5000)
  expect_identical(s1, s2)
  expect_true(s1 > 0)
})

test_that("expected output row counts", {
  k_total <- n_distinct(cells$candidate_id)          # 5 across 2 races
  dr <- generate_forecast_draws_dirichlet(cells, "prov-b/m",
                                          seed = 66, n_draws = N_DRAWS_SMALL)
  expect_equal(nrow(dr), k_total * N_DRAWS_SMALL)     # 5 x 60 = 300
  sm <- summarise_provider_draws(dr, model_points)
  expect_equal(nrow(sm), k_total)
  # model_points covers BOTH providers:
  expect_equal(nrow(model_points),
               k_total * n_distinct(cells$model_id))  # 10
  bias <- forecast_centering_bias(dr, model_points |>
                                    filter(model_id == "prov-b/m"))
  expect_equal(nrow(bias), n_distinct(cells$race_id)) # one leader per race x provider
})

# ---------------------------------------------------------------------------
# p_win and centring-bias reporting
# ---------------------------------------------------------------------------
test_that("provider-specific p_win sums to 1 per race x provider", {
  dr <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                         seed = 77, n_draws = N_DRAWS_SMALL)
  sm <- summarise_provider_draws(dr, model_points)
  sums <- sm |>
    group_by(race_id, model_id) |>
    summarise(s = sum(p_win), .groups = "drop")
  expect_true(all(abs(sums$s - 1) < 1e-12))
  expect_true(all(sm$p_win >= 0 & sm$p_win <= 1))
  expect_false(anyNA(sm$p_win))
})

test_that("leader-centring bias is reported, finite and never silently zero", {
  dr_c <- generate_forecast_draws_centered(cells, calib_points, "prov-a/m",
                                           seed = 88, n_draws = 400)
  bias_c <- forecast_centering_bias(dr_c,
                                    model_points |> filter(model_id == "prov-a/m"))
  expect_true(all(is.finite(bias_c$leader_bias_pp)))
  expect_true(all(bias_c$leader_bias_pp >= -100 & bias_c$leader_bias_pp <= 100))
  # The reported value must match an independent recomputation:
  ref <- dr_c |>
    group_by(race_id, model_id, candidate_id) |>
    summarise(mean_share = mean(share), .groups = "drop") |>
    rename(leader_candidate = candidate_id)
  joined <- bias_c |> inner_join(ref, by = c("race_id", "model_id", "leader_candidate"))
  # reported mean matches an independent recomputation, and the bias
  # column equals the documented formula (both reported, not assumed):
  expect_equal(joined$leader_mean_share, joined$mean_share, tolerance = 1e-12)
  expect_equal(joined$leader_bias_pp,
               100 * (joined$mean_share - joined$leader_point_share))
  # Method A (additive noise) on a many-candidate race must show a clearly
  # NON-zero reported bias: the artifact is measured, not assumed away.
  dr_e <- generate_forecast_draws_existing(cells, "prov-a/m",
                                           seed = 88, n_draws = 400)
  bias_e <- forecast_centering_bias(dr_e,
                                    model_points |> filter(model_id == "prov-a/m"))
  mayor_bias <- abs(bias_e$leader_bias_pp[bias_e$race_id == "mayor"])
  expect_gt(mayor_bias, 1)
})

test_that("original generate_forecast_draws is unchanged in schema", {
  # Original function (mock pipeline) still works on its native input and
  # emits its documented columns.
  dr <- generate_forecast_draws(cells, seed = 99, n_draws = 20)
  expect_true(all(c("race_id", "candidate_id", "draw_id",
                    "source_model_id", "source_repeat_id", "share") %in%
                    names(dr)))
  sums <- dr |> group_by(race_id, draw_id) |>
    summarise(s = sum(share), .groups = "drop")
  expect_true(all(abs(sums$s - 1) < 1e-9))
})

test_that("sigma calibration approximately reaches the target leader sd", {
  p <- c(0.6, 0.2, 0.1, 0.1)
  target <- 0.04
  sigma <- calibrate_forecast_sigma(p, target_sd = target, n_pilot = 40000)
  set.seed(123)
  eps <- matrix(rnorm(40000 * length(p)), nrow = 40000)
  P <- matrix(p, nrow = 40000, ncol = length(p), byrow = TRUE)
  w <- P * exp(sigma * eps)
  s <- w / rowSums(w)
  expect_lt(abs(sd(s[, 1]) - target), 0.005)
})

test_that("forecast_draws_one_model rejects unknown providers", {
  expect_error(
    generate_forecast_draws_dirichlet(cells, "prov-zzz/m", seed = 1, n_draws = 5),
    "not present"
  )
  expect_error(
    forecast_draws_one_model(cells, "prov-a/m", seed = 1, method = "centered"),
    "point_estimates"
  )
})
