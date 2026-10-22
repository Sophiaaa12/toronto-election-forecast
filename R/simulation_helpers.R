# simulation_helpers.R
#
# Shared configuration and pure functions for the simulated silicon
# sampling pipeline (scripts 07-09).
#
# IMPORTANT: No external LLM APIs are called anywhere in this pipeline.
# Every "response" is generated from an explicit, seeded statistical
# model so that the full end-to-end workflow (persona sampling ->
# response generation -> post-stratification -> forecast distributions)
# can be exercised and tested without network access or API credits.
#
# Statistical assumptions implemented here are documented inline and
# summarised in README.md. All magnitudes (incumbency bonus, provider
# bias, forecast noise, undecided/missing rates) are illustrative
# design choices, NOT estimates from election data.

library(dplyr)

# ---------------------------------------------------------------------------
# Fixed seeds: every stage draws its randomness from an independent,
# hard-coded seed so each stage (and the whole pipeline) is exactly
# reproducible.
# ---------------------------------------------------------------------------
SIM_SEEDS <- list(
  personas  = 245307,
  responses = 245308,
  forecast  = 245309
)

# ---------------------------------------------------------------------------
# Persona sampling design
# ---------------------------------------------------------------------------
# Target number of personas. Allocation across the 300 demographic cells
# is proportional to each cell's share of the citywide 20+ population,
# with a minimum floor per cell so that no population cell has zero
# representation.
PERSONA_TARGET_N <- 3000
PERSONA_MIN_PER_CELL <- 5

# ---------------------------------------------------------------------------
# Response model assumptions (mock LLM behaviour)
# ---------------------------------------------------------------------------
# Two placeholder providers. These IDs only label simulation arms; no
# HTTP requests are ever made to them. Each provider is queried three
# independent times per persona-race pair (repeated sampling).
PROVIDER_MODELS <- data.frame(
  provider_id = c("mock-alpha", "mock-beta"),
  model_id = c("mock-alpha/silicon-1", "mock-beta/silicon-1"),
  temperature = c(1.00, 1.15), # choice-noise scale in the softmax
  p_missing = c(0.02, 0.04), # simulated API failure (no usable reply)
  p_invalid = c(0.01, 0.02), # reply received but unparseable
  p_undecided = c(0.10, 0.14), # persona replies "undecided"
  stringsAsFactors = FALSE
)

N_REPEATS <- 3

# Distinct, exhaustive response statuses. "missing" and "invalid" rows are
# always retained (never silently dropped); they carry candidate_id = NA.
RESPONSE_STATUSES <- c(
  "valid_choice", "undecided", "not_voting", "missing", "invalid"
)

# Latent-utility (softmax) model parameters.
INCUMBENT_LOGODDS_BONUS <- 0.90 # ~2.5x odds vs. an average challenger
BASE_STRENGTH_SD <- 1.00 # exchangeable candidate base strengths
AGE_SLOPE_SD <- 0.35 # candidate x age-group preference slopes
EDU_SLOPE_SD <- 0.35 # candidate x education preference slopes
PROVIDER_BIAS_SD <- 0.25 # systematic per-provider candidate framing

# Fixed demographic level order used for slope matrices.
AGE_LEVELS <- c("20-29", "30-44", "45-64", "65+")
EDU_LEVELS <- c(
  "High school or less",
  "Postsecondary below bachelor's",
  "Bachelor's degree or higher"
)

# ---------------------------------------------------------------------------
# Forecast uncertainty assumptions (Monte Carlo draws)
# ---------------------------------------------------------------------------
FORECAST_DRAWS_PER_RACE <- 500
DIRICHLET_PSEUDOCOUNT <- 0.5 # smoothing so zero-support candidates are
# not impossible in the response-sampling
# component of the draws
ASSUMED_FORECAST_SD <- 0.03 # zero-mean Gaussian share noise (3pp),
# truncation at 0 then renormalisation.
# ILLUSTRATIVE, NOT calibrated.

# ---------------------------------------------------------------------------
# Candidate ID scheme (deterministic)
# ---------------------------------------------------------------------------
# candidates_2026.csv carries no official candidate ID column, so IDs are
# assigned deterministically: candidates within each race are sorted by
# ballot_name (then display_name as a tiebreaker) and numbered.
#   mayor:        MAYOR-001 ... MAYOR-053
#   councillors:  W01-C01 ... (per ward)
# A race_id is "mayor" or "ward_XX_councillor". Together this gives one
# mayoral race plus 25 councillor races = 26 races.
build_candidate_crosswalk <- function(candidates) {
  candidates |>
    filter(status == "Active") |>
    mutate(
      race_id = ifelse(
        office == "mayor",
        "mayor",
        sprintf("ward_%02d_councillor", as.integer(ward))
      )
    ) |>
    arrange(race_id, ballot_name, display_name) |>
    group_by(race_id) |>
    mutate(
      candidate_number = row_number(),
      candidate_id = ifelse(
        office == "mayor",
        sprintf("MAYOR-%03d", candidate_number),
        sprintf("W%02d-C%02d", as.integer(ward), candidate_number)
      )
    ) |>
    ungroup() |>
    select(
      candidate_id,
      race_id,
      office,
      ward,
      ballot_name,
      display_name,
      incumbent_name_match
    )
}

# ---------------------------------------------------------------------------
# Persona sampling design
# ---------------------------------------------------------------------------
# Stratified allocation over the 300 population cells (25 wards x 4 age
# x 3 education):
#
#   n_cell = max(min_per_cell, round(N_target * w_cell))
#
# where w_cell is the cell's share of the citywide 20+ population. The
# sampling weight of each persona in cell c is
#
#   sampling_weight = w_cell / n_cell
#
# so that (a) weights sum to 1 over all personas, and (b) the sum of
# weights within a ward equals that ward's share of the citywide 20+
# population. Citywide (mayoral) estimates are therefore automatically
# weighted by ward population; wards are never treated as equally sized.
#
# Every cell has positive representation because of the floor
# (PERSONA_MIN_PER_CELL); with the current frame no cell is left empty.
allocate_population_cells <- function(pop_frame,
                                      n_target = PERSONA_TARGET_N,
                                      min_per_cell = PERSONA_MIN_PER_CELL) {
  pop_frame |>
    mutate(
      cell_prop_citywide = estimated_population / sum(estimated_population),
      n_personas = pmax(min_per_cell, round(n_target * cell_prop_citywide))
    )
}

# ---------------------------------------------------------------------------
# Mock LLM response simulation
# ---------------------------------------------------------------------------
# Generative model (all seeded):
#
# 1. Candidate parameters per race (drawn once):
#      base_k       ~ N(0, BASE_STRENGTH_SD)       exchangeable strengths
#      inc bonus    = INCUMBENT_LOGODDS_BONUS if incumbent_name_match
#      age slopes   ~ N(0, AGE_SLOPE_SD)           per candidate x age group
#      edu slopes   ~ N(0, EDU_SLOPE_SD)           per candidate x education
#    The only real-world electoral signal used is incumbency status from
#    the official 2026 candidate list.
#
# 2. Provider-specific framing: bias_{m,k} ~ N(0, PROVIDER_BIAS_SD),
#    constant across repeats (a systematic provider effect).
#
# 3. Persona-level turnout intent, drawn ONCE per persona per race with
#    probability equal to 2022 turnout of the race's geography (ward
#    turnout for councillor races; citywide turnout for the mayoral race).
#    Persona intent is fixed across repeats; only query-level noise
#    varies between repeats.
#
# 4. Per query (persona x race x provider x repeat), statuses are drawn
#    in order: missing -> invalid -> not_voting -> undecided -> choice.
#    Undecided and invalid/missing rates are provider specific.
#
# 5. A valid choice is a categorical draw with probabilities
#    softmax((utility + provider bias) / temperature).
simulate_llm_responses <- function(personas,
                                   candidates,
                                   turnout_by_ward,
                                   citywide_turnout = NULL,
                                   seed = SIM_SEEDS$responses) {
  set.seed(seed)

  crosswalk <- build_candidate_crosswalk(candidates)

  if (is.null(citywide_turnout)) {
    citywide_turnout <- with(
      turnout_by_ward,
      sum(ballots_cast) / sum(eligible_electors)
    )
  }

  races <- sort(unique(crosswalk$race_id))
  models <- PROVIDER_MODELS

  out <- list()

  # Per-candidate provider framing bias (one matrix for all races).
  n_cand <- nrow(crosswalk)
  bias_mat <- matrix(
    rnorm(nrow(models) * n_cand, sd = PROVIDER_BIAS_SD),
    nrow = nrow(models)
  )
  cand_order <- crosswalk |> arrange(candidate_id)
  bias_lookup <- setNames(
    lapply(seq_len(nrow(models)), function(m) setNames(bias_mat[m, ], cand_order$candidate_id)),
    models$model_id
  )

  for (ri in seq_along(races)) {
    race <- races[ri]
    cand <- crosswalk |>
      filter(race_id == race) |>
      arrange(candidate_id)
    cand_ids <- cand$candidate_id
    K <- length(cand_ids)

    # Personas eligible for this race: everyone for mayor, ward
    # residents for a councillor race.
    ward_of_race <- if (race == "mayor") {
      NULL
    } else {
      as.integer(sub("ward_([0-9]{2})_councillor", "\\1", race))
    }
    p <- if (is.null(ward_of_race)) {
      personas
    } else {
      personas |> filter(ward == ward_of_race)
    }
    n <- nrow(p)

    # Latent utility matrix U[i, k] for persona i, candidate k.
    base <- cand$incumbent_name_match * INCUMBENT_LOGODDS_BONUS
    age_idx <- match(p$age_group, AGE_LEVELS)
    edu_idx <- match(p$education_group, EDU_LEVELS)
    age_slope <- matrix(rnorm(K * length(AGE_LEVELS), sd = AGE_SLOPE_SD), nrow = K)
    edu_slope <- matrix(rnorm(K * length(EDU_LEVELS), sd = EDU_SLOPE_SD), nrow = K)
    U <- matrix(rep(base, each = n), nrow = n) +
      t(age_slope[, age_idx, drop = FALSE]) +
      t(edu_slope[, edu_idx, drop = FALSE])

    # Persona-level turnout intent for this race (fixed across repeats).
    turnout_r <- if (is.null(ward_of_race)) {
      citywide_turnout
    } else {
      turnout_by_ward$turnout[turnout_by_ward$ward == ward_of_race]
    }
    will_vote <- rbinom(n, 1, turnout_r) == 1

    for (mi in seq_len(nrow(models))) {
      prov <- models[mi, ]
      bias <- bias_lookup[[prov$model_id]]
      logits <- sweep(
        sweep(U, 2, bias[cand_ids], `+`),
        2,
        prov$temperature,
        `/`
      )
      # Row-wise softmax probabilities.
      logits <- logits - apply(logits, 1, max)
      probs <- exp(logits)
      probs <- probs / rowSums(probs)

      for (rep_id in seq_len(N_REPEATS)) {
        status <- rep("valid_choice", n)
        choice <- rep(NA_character_, n)

        is_missing <- runif(n) < prov$p_missing
        status[is_missing] <- "missing"

        keep <- which(!is_missing)
        is_invalid <- runif(length(keep)) < prov$p_invalid
        status[keep[is_invalid]] <- "invalid"
        keep <- keep[!is_invalid]

        is_notvoting <- !will_vote[keep]
        status[keep[is_notvoting]] <- "not_voting"
        keep <- keep[!is_notvoting]

        is_undecided <- runif(length(keep)) < prov$p_undecided
        status[keep[is_undecided]] <- "undecided"
        keep <- keep[!is_undecided]

        if (length(keep) > 0) {
          idx <- vapply(
            keep,
            function(i) sample.int(K, 1, prob = probs[i, ]),
            integer(1)
          )
          choice[keep] <- cand_ids[idx]
        }

        out[[length(out) + 1]] <- data.frame(
          persona_id = p$persona_id,
          ward = p$ward,
          race_id = race,
          candidate_id = choice,
          provider_id = prov$provider_id,
          model_id = prov$model_id,
          repeat_id = rep_id,
          response_status = status,
          stringsAsFactors = FALSE
        )
      }
    }
  }

  dplyr::bind_rows(out) |>
    arrange(persona_id, race_id, model_id, repeat_id)
}

# ---------------------------------------------------------------------------
# Post-stratification
# ---------------------------------------------------------------------------
# Estimation target: each candidate's share of VALID first preferences
# (i.e. among decided respondents) in the race's elector population,
# where every persona carries its design (census) weight w_i.
#
#   share_k = sum_i w_i * 1[choice_i = k] / sum_i w_i
#
# over valid_choice responses only. Undecided, not_voting, missing and
# invalid responses are excluded from BOTH numerator and denominator
# (they are never silently dropped from the response dataset itself).
# Cells in which no persona gives a valid response simply contribute no
# weight; the estimate renormalises over the responding cells.
#
# For ward councillor races the sum runs over personas in that ward.
# For the mayoral race the sum runs over ALL personas with citywide
# weights, so ward population sizes enter automatically.
#
# Also returns the Kish effective sample size
#   n_eff = (sum w)^2 / sum(w^2)
# per race x provider x repeat cell, used later as the Dirichlet
# concentration scale for response sampling variability.
#
# `model_ids` and `n_repeats` default to the simulated pipeline's own
# settings (PROVIDER_MODELS / N_REPEATS). They are parameters only so
# that REAL LLM responses (R/10_llm_poststratify.R), which carry their
# own model IDs and repeat counts, can flow through this exact same
# function unchanged. No methodology is altered by the parameterization.
poststratify_responses <- function(responses,
                                   personas,
                                   crosswalk,
                                   model_ids = PROVIDER_MODELS$model_id,
                                   n_repeats = N_REPEATS) {
  valid <- responses |>
    filter(response_status == "valid_choice") |>
    left_join(
      personas |> select(persona_id, sampling_weight),
      by = "persona_id"
    )

  cells <- valid |>
    group_by(race_id, model_id, repeat_id, candidate_id) |>
    summarise(
      weighted_support = sum(sampling_weight),
      .groups = "drop"
    )

  cell_totals <- valid |>
    group_by(race_id, model_id, repeat_id) |>
    summarise(
      n_valid = n(),
      sum_w   = sum(sampling_weight),
      sum_w2  = sum(sampling_weight^2),
      .groups = "drop"
    ) |>
    mutate(n_eff = ifelse(sum_w2 > 0, sum_w^2 / sum_w2, 0))

  # Expand to the full candidate grid so zero-support candidates appear
  # with share exactly 0 rather than being omitted.
  grid <- crosswalk |>
    select(race_id, candidate_id) |>
    distinct() |>
    tidyr::expand_grid(
      model_id  = model_ids,
      repeat_id = seq_len(n_repeats)
    )

  cells <- grid |>
    left_join(cells, by = c("race_id", "model_id", "repeat_id", "candidate_id")) |>
    mutate(weighted_support = ifelse(is.na(weighted_support), 0, weighted_support)) |>
    left_join(cell_totals, by = c("race_id", "model_id", "repeat_id")) |>
    mutate(share = weighted_support / sum_w) |>
    mutate(share = ifelse(is.na(share), 0, share))

  # Pooled point estimate: pool valid responses across both simulated
  # providers and all three repeats (each persona-race pair contributes
  # up to 6 responses, equally weighted).
  point <- valid |>
    group_by(race_id, candidate_id) |>
    summarise(
      n_valid = n(),
      weighted_support = sum(sampling_weight),
      .groups = "drop"
    ) |>
    group_by(race_id) |>
    mutate(point_share = weighted_support / sum(weighted_support)) |>
    ungroup() |>
    right_join(
      crosswalk |> select(race_id, candidate_id),
      by = c("race_id", "candidate_id")
    ) |>
    mutate(
      point_share = ifelse(is.na(point_share), 0, point_share),
      n_valid = ifelse(is.na(n_valid), 0L, n_valid)
    ) |>
    select(race_id, candidate_id, n_valid, point_share) |>
    arrange(race_id, candidate_id)

  list(cells = cells, point = point)
}

# ---------------------------------------------------------------------------
# Forecast distributions (Monte Carlo draws)
# ---------------------------------------------------------------------------
# Each draw separates three explicit sources of variation:
#
#   1. model/provider variation: the draw first resamples one of the
#      2 providers x 3 repeats post-stratified cells uniformly;
#   2. response sampling variability: candidate shares are then drawn
#      from a Dirichlet distribution with concentration
#      alpha_k = n_eff * share_k + DIRICHLET_PSEUDOCOUNT;
#   3. assumed forecast uncertainty: independent zero-mean Gaussian
#      noise with sd = ASSUMED_FORECAST_SD is added to each share,
#      truncated at zero and renormalised.
#
# The resulting intervals are ILLUSTRATIVE simulation output. They are
# NOT calibrated measures of real election uncertainty.
generate_forecast_draws <- function(cell_estimates,
                                    seed = SIM_SEEDS$forecast,
                                    n_draws = FORECAST_DRAWS_PER_RACE) {
  set.seed(seed)

  races <- sort(unique(cell_estimates$race_id))
  out <- vector("list", length(races))

  for (ri in seq_along(races)) {
    race <- races[ri]
    est <- cell_estimates |> filter(race_id == race)
    cells <- est |>
      distinct(model_id, repeat_id) |>
      arrange(model_id, repeat_id)
    cand_ids <- sort(unique(est$candidate_id))
    K <- nrow(cells)
    n_cand <- length(cand_ids)

    share_mat <- matrix(0, nrow = K, ncol = n_cand)
    neff_vec <- numeric(K)
    for (j in seq_len(K)) {
      sub <- est |>
        filter(
          model_id == cells$model_id[j],
          repeat_id == cells$repeat_id[j]
        )
      share_mat[j, ] <- sub$share[match(cand_ids, sub$candidate_id)]
      neff_vec[j] <- sub$n_eff[1]
    }

    draw_mat <- matrix(0, nrow = n_draws, ncol = n_cand)
    src_cell <- integer(n_draws)
    for (d in seq_len(n_draws)) {
      j <- sample.int(K, 1)
      alpha <- neff_vec[j] * share_mat[j, ] + DIRICHLET_PSEUDOCOUNT
      s <- rgamma(n_cand, shape = alpha)
      s <- s / sum(s)
      s <- s + rnorm(n_cand, sd = ASSUMED_FORECAST_SD)
      s <- pmax(s, 0)
      s <- s / sum(s)
      draw_mat[d, ] <- s
      src_cell[d] <- j
    }

    out[[ri]] <- data.frame(
      race_id          = race,
      candidate_id     = rep(cand_ids, each = n_draws),
      draw_id          = rep(seq_len(n_draws), times = n_cand),
      source_model_id  = cells$model_id[src_cell][rep(seq_len(n_draws), times = n_cand)],
      source_repeat_id = cells$repeat_id[src_cell][rep(seq_len(n_draws), times = n_cand)],
      share            = as.vector(draw_mat),
      stringsAsFactors = FALSE
    )
  }

  dplyr::bind_rows(out) |>
    arrange(race_id, candidate_id, draw_id)
}

# ---------------------------------------------------------------------------
# Forecast summary
# ---------------------------------------------------------------------------
summarise_forecast_draws <- function(draws, point_estimates) {
  win_rates <- draws |>
    group_by(race_id, draw_id) |>
    mutate(is_win = share == max(share)) |>
    ungroup() |>
    group_by(race_id, candidate_id) |>
    summarise(p_win = mean(is_win), .groups = "drop")

  draws |>
    group_by(race_id, candidate_id) |>
    summarise(
      mean_share = mean(share),
      sd_share = sd(share),
      q025 = as.numeric(quantile(share, 0.025)),
      q50 = as.numeric(quantile(share, 0.5)),
      q975 = as.numeric(quantile(share, 0.975)),
      .groups = "drop"
    ) |>
    left_join(win_rates, by = c("race_id", "candidate_id")) |>
    left_join(point_estimates, by = c("race_id", "candidate_id")) |>
    arrange(race_id, candidate_id)
}

# ===========================================================================
# Task 6C: revised uncertainty construction (Methods B and C)
# ===========================================================================
# This section only ADDS functions. generate_forecast_draws() above is
# left byte-identical so every previously produced mock/simulated forecast
# output remains exactly reproducible (requirement: original unchanged).
#
# Variance sources, kept explicitly distinct:
#
#   1. LLM response variability: each draw first resamples one of the
#      source provider's REPEAT cells (3 repeats within ONE model), so
#      provider disagreement is never averaged away -- forecast draws are
#      produced separately for each provider.
#
#   2. Dirichlet sampling uncertainty: shares ~ Dirichlet(n_eff * share
#      + DIRICHLET_PSEUDOCOUNT), where n_eff is the Kish effective sample
#      size of the post-stratified cell. The +0.5 pseudocount is a
#      uniform-prior Dirichlet smoother: the cell posterior mean shrinks
#      toward uniform by  0.5 * (1 - K * share) / (n_eff + 0.5 * K),
#      and the total mass it gives zero-support candidates is
#      0.5 * K / (n_eff + 0.5 * K). This effect is material when n_eff is
#      small and K is large; R/10_llm_poststratify.R reports it per race.
#
#   3. Assumed forecast perturbation (Method C only): multiplicative
#      logistic-normal noise  s_k <- s_k * exp(sigma * eps_k),
#      eps_k ~ iid N(0,1), renormalised to the simplex. sigma is
#      calibrated per race (calibrate_forecast_sigma) so this layer ALONE
#      gives the race leader a marginal sd of target_sd (default
#      FORECAST_TARGET_SD = 4pp). Unlike the additive-Gaussian layer in
#      generate_forecast_draws(), this layer injects no positive mass
#      (exact zeros stay exact zeros) and its absolute effect does not
#      grow with the number of candidates.
#      Method C is only APPROXIMATELY centre-preserving: the multiplicative
#      perturbation plus renormalisation leaves a small O(sigma^2)
#      displacement of the draw mean from the source shares. The realised
#      leader bias is therefore computed and REPORTED (see
#      forecast_centering_bias), never assumed to be zero.
#
#   4. Real election uncertainty: NOT modelled by any of these methods.
#      All intervals and win frequencies are conditional on (a) the LLM
#      responses and (b) the assumed perturbation scale. They are
#      illustrative simulation frequencies, not calibrated probabilities
#      of winning a real election.
#
# Method dispatch (used by R/10_llm_poststratify.R):
#   generate_forecast_draws_centered()   Method C (production default)
#   generate_forecast_draws_dirichlet()  Method B (sampling only)
#   generate_forecast_draws_existing()   Method A construction, evaluated
#                                        per provider (Dirichlet + additive
#                                        N(0, 3pp^2) + clip + renormalise)
FORECAST_TARGET_SD <- 0.04 # Method C default: 4pp leader sd from the
# perturbation layer alone. ILLUSTRATIVE;
# NOT calibrated to election history.
FORECAST_TARGET_SD_GRID <- c(0.02, 0.04, 0.06) # sensitivity grid (6C)
CALIBRATION_SEED <- 245310L # sigma-calibration RNG (independent of
# the draw seed, so calibration is
# reproducible on its own)
CALIBRATION_PILOT_N <- 20000L

# Calibrate the multiplicative perturbation scale sigma for one race so
# that, applied to the race's reference point shares, the perturbation
# layer alone produces a leader sd of `target_sd`. Returns sigma in
# [lo, hi]; saturates at the cap if the target is unreachable (e.g. an
# almost-unanimous leader whose sd is bounded by sqrt(p*(1-p))).
# NOTE: reseeds the global RNG (CALIBRATION_SEED); callers should
# set.seed() for the draw stream AFTER calibrating.
calibrate_forecast_sigma <- function(point_shares,
                                     target_sd = FORECAST_TARGET_SD,
                                     n_pilot = CALIBRATION_PILOT_N,
                                     seed = CALIBRATION_SEED,
                                     lo = 1e-4, hi = 10) {
  stopifnot(
    length(point_shares) >= 2,
    all(is.finite(point_shares)),
    all(point_shares >= 0),
    abs(sum(point_shares) - 1) < 1e-6,
    target_sd > 0
  )
  leader <- which.max(point_shares)
  set.seed(seed)
  eps <- matrix(rnorm(n_pilot * length(point_shares)), nrow = n_pilot)
  P <- matrix(point_shares,
    nrow = n_pilot,
    ncol = length(point_shares), byrow = TRUE
  )
  leader_sd <- function(sig) {
    w <- P * exp(sig * eps) # exact zeros remain exact zeros
    s <- w / rowSums(w)
    sd(s[, leader])
  }
  if (leader_sd(lo) >= target_sd) {
    return(lo)
  }
  if (leader_sd(hi) <= target_sd) {
    return(hi)
  }
  uniroot(function(x) leader_sd(x) - target_sd, interval = c(lo, hi))$root
}

# The multiplicative layer itself, exposed for unit testing:
# preserves the simplex, preserves exact zeros, scale-free in shares.
apply_multiplicative_layer <- function(shares, sigma,
                                       eps = rnorm(length(shares))) {
  stopifnot(
    length(shares) == length(eps),
    all(is.finite(shares)),
    all(shares >= 0),
    sigma >= 0,
    sum(shares) > 0
  )
  w <- shares * exp(sigma * eps)
  stopifnot(sum(w) > 0)
  w / sum(w)
}

# Dirichlet-mean shrinkage caused by the +0.5 pseudocount, in percentage
# points, for a candidate with cell share `share` in a K-candidate race
# with effective sample size n_eff (positive = upward pull toward uniform).
pseudocount_shrinkage_pp <- function(n_eff, n_cand, share) {
  100 * DIRICHLET_PSEUDOCOUNT * (1 - n_cand * share) /
    (n_eff + DIRICHLET_PSEUDOCOUNT * n_cand)
}

# Total mass the +0.5 pseudocount puts on zero-support candidates (%).
pseudocount_mass_pct <- function(n_eff, n_cand) {
  100 * DIRICHLET_PSEUDOCOUNT * n_cand /
    (n_eff + DIRICHLET_PSEUDOCOUNT * n_cand)
}

# ---------------------------------------------------------------------------
# Shared draw worker: one provider's cells, methods A/B/C, identical
# output schema. The provider's draws resample ONLY that provider's
# repeat cells (provider-specific forecasts).
# ---------------------------------------------------------------------------
forecast_draws_one_model <- function(cell_estimates,
                                     model_id,
                                     seed,
                                     n_draws = FORECAST_DRAWS_PER_RACE,
                                     method = c(
                                       "centered", "dirichlet",
                                       "existing"
                                     ),
                                     target_sd = FORECAST_TARGET_SD,
                                     point_estimates = NULL) {
  method <- match.arg(method)
  est <- cell_estimates[cell_estimates$model_id == model_id, , drop = FALSE]
  if (nrow(est) == 0) {
    stop("model_id '", model_id, "' not present in cell_estimates")
  }
  races <- sort(unique(est$race_id))

  # Method C: one calibrated sigma per race, from the race's reference
  # (pooled descriptive) point shares; calibration runs before the draw
  # seed is set so both are independently reproducible.
  sigmas <- NULL
  if (method == "centered") {
    if (is.null(point_estimates)) {
      stop("method = 'centered' requires point_estimates for sigma calibration")
    }
    sigmas <- stats::setNames(numeric(length(races)), races)
    for (r in races) {
      ps <- point_estimates$point_share[point_estimates$race_id == r]
      if (length(ps) == 0) stop("no reference point shares for race '", r, "'")
      sigmas[[r]] <- calibrate_forecast_sigma(ps, target_sd = target_sd)
    }
  }

  set.seed(seed)
  out <- vector("list", length(races))
  for (ri in seq_along(races)) {
    race <- races[ri]
    sub <- est[est$race_id == race, , drop = FALSE]
    reps <- sort(unique(sub$repeat_id))
    cand_ids <- sort(unique(sub$candidate_id))
    n_rep <- length(reps)
    n_cand <- length(cand_ids)

    share_mat <- matrix(0, nrow = n_rep, ncol = n_cand)
    neff_vec <- numeric(n_rep)
    for (j in seq_len(n_rep)) {
      rows <- sub[sub$repeat_id == reps[j], , drop = FALSE]
      share_mat[j, ] <- rows$share[match(cand_ids, rows$candidate_id)]
      neff_vec[j] <- rows$n_eff[1]
    }

    draw_mat <- matrix(0, nrow = n_draws, ncol = n_cand)
    src <- integer(n_draws)
    sigma_r <- if (method == "centered") sigmas[[race]] else NA_real_
    for (d in seq_len(n_draws)) {
      j <- sample.int(n_rep, 1L)
      # Layer 2: Dirichlet sampling uncertainty (+ pseudocount)
      alpha <- neff_vec[j] * share_mat[j, ] + DIRICHLET_PSEUDOCOUNT
      s <- rgamma(n_cand, shape = alpha)
      s <- s / sum(s)
      if (method == "existing") {
        # Layer 3 (original construction): additive Gaussian, clip, renorm
        s <- s + rnorm(n_cand, sd = ASSUMED_FORECAST_SD)
        s <- pmax(s, 0)
        s <- s / sum(s)
      } else if (method == "centered") {
        # Layer 3 (Method C): multiplicative logistic-normal perturbation
        s <- apply_multiplicative_layer(s, sigma_r)
      }
      draw_mat[d, ] <- s
      src[d] <- j
    }

    out[[ri]] <- data.frame(
      race_id          = race,
      model_id         = model_id,
      candidate_id     = rep(cand_ids, each = n_draws),
      draw_id          = rep(seq_len(n_draws), times = n_cand),
      source_repeat_id = reps[src][rep(seq_len(n_draws), times = n_cand)],
      share            = as.vector(draw_mat),
      stringsAsFactors = FALSE
    )
  }
  dplyr::bind_rows(out) |>
    dplyr::arrange(race_id, candidate_id, draw_id)
}

# Method C -- revised production forecast draws (see section header above).
# `point_estimates` supplies the race-level reference shares used only to
# calibrate sigma (equal-weight pooled descriptive shares); the draws
# themselves always come from a single provider's repeat cells.
generate_forecast_draws_centered <- function(cell_estimates,
                                             point_estimates,
                                             model_id,
                                             seed = SIM_SEEDS$forecast,
                                             n_draws = FORECAST_DRAWS_PER_RACE,
                                             target_sd = FORECAST_TARGET_SD) {
  forecast_draws_one_model(
    cell_estimates, model_id, seed, n_draws,
    method = "centered", target_sd = target_sd,
    point_estimates = point_estimates
  )
}

# Method B: Dirichlet sampling uncertainty only.
generate_forecast_draws_dirichlet <- function(cell_estimates,
                                              model_id,
                                              seed = SIM_SEEDS$forecast,
                                              n_draws = FORECAST_DRAWS_PER_RACE) {
  forecast_draws_one_model(cell_estimates, model_id, seed, n_draws,
    method = "dirichlet"
  )
}

# Method A construction (Dirichlet + additive Gaussian + clip + renorm),
# evaluated per provider so it is directly comparable to B and C.
generate_forecast_draws_existing <- function(cell_estimates,
                                             model_id,
                                             seed = SIM_SEEDS$forecast,
                                             n_draws = FORECAST_DRAWS_PER_RACE) {
  forecast_draws_one_model(cell_estimates, model_id, seed, n_draws,
    method = "existing"
  )
}

# Summary for provider-specific draws. Unlike summarise_forecast_draws()
# (left unchanged for the mock pipeline), ties are broken so that EXACTLY
# ONE candidate wins each draw, guaranteeing p_win sums to 1 per
# race x provider. point_estimates needs race_id, model_id, candidate_id,
# n_valid, point_share (provider-specific, equal weight over repeats).
summarise_provider_draws <- function(draws, point_estimates) {
  wins <- draws |>
    dplyr::group_by(race_id, model_id, draw_id) |>
    dplyr::mutate(is_win = dplyr::row_number() == which.max(share)) |>
    dplyr::ungroup() |>
    dplyr::group_by(race_id, model_id, candidate_id) |>
    dplyr::summarise(p_win = mean(is_win), .groups = "drop")

  draws |>
    dplyr::group_by(race_id, model_id, candidate_id) |>
    dplyr::summarise(
      mean_share = mean(share),
      sd_share = sd(share),
      q025 = as.numeric(stats::quantile(share, 0.025)),
      q50 = as.numeric(stats::quantile(share, 0.5)),
      q975 = as.numeric(stats::quantile(share, 0.975)),
      .groups = "drop"
    ) |>
    dplyr::left_join(wins, by = c("race_id", "model_id", "candidate_id")) |>
    dplyr::left_join(
      point_estimates,
      by = c("race_id", "model_id", "candidate_id")
    ) |>
    dplyr::arrange(race_id, model_id, candidate_id)
}

# Realised leader-centring bias of a set of provider-specific draws:
# draw mean minus the provider's point share for that race's point leader.
# This is REPORTED (never assumed to be zero): Method C is only
# approximately centre-preserving, and Method A is strongly biased.
forecast_centering_bias <- function(draws, point_estimates) {
  leaders <- point_estimates |>
    dplyr::group_by(race_id, model_id) |>
    dplyr::slice_max(point_share, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::select(race_id, model_id, candidate_id, point_share)

  draws |>
    dplyr::group_by(race_id, model_id, candidate_id) |>
    dplyr::summarise(
      mean_share = mean(share),
      sd_share = stats::sd(share),
      .groups = "drop"
    ) |>
    dplyr::inner_join(leaders, by = c("race_id", "model_id", "candidate_id")) |>
    dplyr::mutate(
      leader_candidate    = candidate_id,
      leader_bias_pp      = 100 * (mean_share - point_share),
      leader_point_share  = point_share,
      leader_mean_share   = mean_share,
      leader_sd_share     = sd_share
    ) |>
    dplyr::select(
      race_id, model_id, leader_candidate,
      leader_point_share, leader_mean_share, leader_bias_pp,
      leader_sd_share
    )
}
