# R/10_llm_poststratify.R
#
# Bridge from REAL LLM responses to the existing forecast pipeline.
#
# This script is the hand-off point between the Python OpenRouter
# sampling layer (llm/runner.py) and the R statistical layer. It:
#
#   1. reads processed/llm_responses.parquet (written by llm/runner.py);
#   2. VALIDATES it against the schema expected by the simulation
#      pipeline (required columns, status vocabulary, candidate/race
#      membership, persona coverage);
#   3. runs the UNCHANGED statistical functions from
#      R/simulation_helpers.R (poststratify_responses,
#      generate_forecast_draws, summarise_forecast_draws);
#   4. writes forecast outputs to a SEPARATE directory
#      (processed/llm/...) so no simulated output is ever overwritten.
#
# IMPORTANT:
#   - No real LLM sampling has been performed at the time this file was
#     written. This script is a no-op until processed/llm_responses.parquet
#     exists; it prints a clear message and exits successfully.
#   - The methodology is NOT modified here. poststratify_responses() is
#     called with model_ids / n_repeats derived from the real responses,
#     which is a parameterization of the same function used by script 09.
#
# Usage:
#   Rscript R/10_llm_poststratify.R
#
# Inputs:
#   processed/llm_responses.parquet          (required, from llm/runner.py)
#   processed/simulated/simulated_personas.parquet   (design weights)
#   processed/simulated/candidate_crosswalk.parquet  (candidate grid)
#
# Outputs (all under processed/llm/, never under processed/simulated/):
#   processed/llm/llm_cell_estimates.parquet
#   processed/llm/llm_forecast_draws.parquet
#   processed/llm/llm_forecast_summary.parquet

library(dplyr)
library(nanoparquet)

source(file.path("R", "simulation_helpers.R"))

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
# Main
# ---------------------------------------------------------------------------

run_llm_poststratify <- function(llm_path = file.path("processed", "llm_responses.parquet"),
                                 personas_path = file.path("processed", "simulated", "simulated_personas.parquet"),
                                 crosswalk_path = file.path("processed", "simulated", "candidate_crosswalk.parquet"),
                                 out_dir = file.path("processed", "llm"),
                                 n_draws = FORECAST_DRAWS_PER_RACE,
                                 seed = SIM_SEEDS$forecast) {
  if (!file.exists(llm_path)) {
    message(
      "No real LLM responses found at '", llm_path, "'.\n",
      "No real LLM sampling has been run yet. Produce this file with:\n",
      "  python3 -m llm.runner run --config llm/models.json --budget-usd <N>\n",
      "See README.md (\"Real LLM sampling\") for setup, then re-run:\n",
      "  Rscript R/10_llm_poststratify.R"
    )
    return(invisible(NULL))
  }

  responses <- read_parquet(llm_path)
  personas  <- read_parquet(personas_path)
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

  # Derive the model/repeat grid actually present in the data so the
  # same statistics apply regardless of configuration.
  model_ids <- sort(unique(responses$model_id))
  n_repeats <- max(responses$repeat_id, na.rm = TRUE)

  cell_estimates <- poststratify_responses(
    responses  = responses,
    personas   = personas,
    crosswalk  = crosswalk,
    model_ids  = model_ids,
    n_repeats  = n_repeats
  )$cells

  draws <- generate_forecast_draws(
    cell_estimates = cell_estimates,
    seed           = seed,
    n_draws        = n_draws
  )

  summary_tbl <- summarise_forecast_draws(
    draws           = draws,
    point_estimates = cell_estimates
  )

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  write_parquet(cell_estimates, file.path(out_dir, "llm_cell_estimates.parquet"))
  write_parquet(draws,          file.path(out_dir, "llm_forecast_draws.parquet"))
  write_parquet(summary_tbl,    file.path(out_dir, "llm_forecast_summary.parquet"))

  message(
    "LLM forecast written to ", out_dir, "/\n",
    "  cell estimate rows: ", nrow(cell_estimates), "\n",
    "  draw rows:          ", nrow(draws), "\n",
    "  summary rows:       ", nrow(summary_tbl)
  )
  invisible(list(
    cell_estimates = cell_estimates,
    draws          = draws,
    summary        = summary_tbl
  ))
}

# Run when executed as a script (Rscript) rather than sourced in tests.
if (sys.nframe() == 0) {
  run_llm_poststratify()
}
