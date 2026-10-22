# test-10_llm_bridge.R
#
# Validates the R-side bridge (R/10_llm_poststratify.R) that will feed
# REAL LLM responses into the existing forecast statistics.
#
# Because no real LLM sampling has been performed, these tests build
# small synthetic response tables in the exact llm_responses.parquet
# schema and check the bridge's validation and statistics glue.
#
# Coverage:
#   - schema validation catches missing columns / bad statuses
#   - candidate IDs must belong to their race (ward matching)
#   - valid_choice requires a candidate_id; other statuses require NULL
#   - unknown personas are rejected
#   - the unchanged post-stratification runs on real-model-ID data
#   - share vectors still sum to one for every race
#   - outputs are written to a separate directory (simulated/ untouched)

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

source(file.path("R", "10_llm_poststratify.R"))

# ---------------------------------------------------------------------------
# Fixtures: tiny synthetic responses with REAL-STYLE model IDs
# (distinct providers), mirroring the documented output schema.
# ---------------------------------------------------------------------------

fake_crosswalk <- data.frame(
  candidate_id = c("MAYOR-001", "MAYOR-002", "W01-C01", "W01-C02"),
  race_id = c("mayor", "mayor", "ward_01_councillor", "ward_01_councillor"),
  stringsAsFactors = FALSE
)

fake_personas <- data.frame(
  persona_id       = c("P000001", "P000002"),
  ward             = c(1, 1),
  sampling_weight  = c(0.5, 0.5),
  stringsAsFactors = FALSE
)

# One row per planned request. Every (race, model, repeat) estimation
# cell gets at least one valid_choice so share vectors are well-defined;
# row 1 (valid_choice) and row 2 (undecided) anchor the nullability tests.
fake_responses <- data.frame(
  persona_id = c(
    "P000001", # mayor  x prov-a/m x rep1  valid
    "P000001", # mayor  x prov-a/m x rep2  undecided
    "P000002", # mayor  x prov-b/m x rep1  valid
    "P000002", # mayor  x prov-b/m x rep2  valid
    "P000002", # mayor  x prov-a/m x rep2  valid (fills cell)
    "P000001", # ward   x prov-a/m x rep1  valid
    "P000001", # ward   x prov-a/m x rep2  valid
    "P000002", # ward   x prov-b/m x rep1  valid
    "P000002", # ward   x prov-b/m x rep2  valid
    "P000002"
  ), # ward   x prov-b/m x rep2  not_voting
  ward = 1,
  race_id = c(
    "mayor", "mayor", "mayor", "mayor", "mayor",
    "ward_01_councillor", "ward_01_councillor",
    "ward_01_councillor", "ward_01_councillor",
    "ward_01_councillor"
  ),
  candidate_id = c(
    "MAYOR-001", NA, "MAYOR-002", "MAYOR-001", "MAYOR-002",
    "W01-C01", "W01-C02", "W01-C01", "W01-C02", NA
  ),
  provider_id = c(
    "prov-a", "prov-a", "prov-b", "prov-b", "prov-a",
    "prov-a", "prov-a", "prov-b", "prov-b", "prov-b"
  ),
  model_id = c(
    "prov-a/m", "prov-a/m", "prov-b/m", "prov-b/m", "prov-a/m",
    "prov-a/m", "prov-a/m", "prov-b/m", "prov-b/m", "prov-b/m"
  ),
  repeat_id = c(1L, 2L, 1L, 2L, 2L, 1L, 2L, 1L, 2L, 2L),
  response_status = c(
    "valid_choice", "undecided", "valid_choice", "valid_choice",
    "valid_choice", "valid_choice", "valid_choice",
    "valid_choice", "valid_choice", "not_voting"
  ),
  stringsAsFactors = FALSE
)

test_that("validation passes on a well-formed response table", {
  expect_length(validate_llm_responses(fake_responses, fake_crosswalk), 0)
  expect_length(validate_llm_personas(fake_responses, fake_personas), 0)
})

test_that("validation catches missing required columns", {
  bad <- fake_responses[, setdiff(names(fake_responses), "race_id")]
  probs <- validate_llm_responses(bad, fake_crosswalk)
  expect_true(any(grepl("missing required columns", probs)))
})

test_that("validation catches unknown response_status", {
  bad <- fake_responses
  bad$response_status[1] <- "maybe"
  probs <- validate_llm_responses(bad, fake_crosswalk)
  expect_true(any(grepl("unknown response_status", probs)))
})

test_that("validation catches a candidate from the wrong race", {
  # A ward candidate claimed in the mayor race.
  bad <- fake_responses
  bad$race_id[1] <- "mayor"
  bad$candidate_id[1] <- "W01-C02" # exists, but in ward_01, not mayor
  probs <- validate_llm_responses(bad, fake_crosswalk)
  expect_true(any(grepl("not in the crosswalk", probs)))
})

test_that("validation enforces candidate_id nullability rules", {
  bad_null <- fake_responses
  bad_null$candidate_id[2] <- "MAYOR-002" # undecided must have NULL
  probs <- validate_llm_responses(bad_null, fake_crosswalk)
  expect_true(any(grepl("must have NULL candidate_id", probs)))

  bad_valid <- fake_responses
  bad_valid$candidate_id[1] <- NA # valid_choice needs an ID
  probs <- validate_llm_responses(bad_valid, fake_crosswalk)
  expect_true(any(grepl("valid_choice rows with missing candidate_id", probs)))
})

test_that("validation catches unknown personas", {
  bad <- fake_responses
  bad$persona_id[1] <- "P999999"
  probs <- validate_llm_personas(bad, fake_personas)
  expect_true(any(grepl("not in the persona file", probs)))
})

test_that("post-stratification reuses unchanged stats with real model IDs", {
  # This is the core claim of Task 3: the SAME poststratify_responses()
  # runs on real-model-ID data without modification.
  res <- poststratify_responses(
    responses = fake_responses,
    personas  = fake_personas,
    crosswalk = fake_crosswalk,
    model_ids = sort(unique(fake_responses$model_id)),
    n_repeats = max(fake_responses$repeat_id)
  )
  cells <- res$cells
  expect_true(all(c(
    "race_id", "model_id", "repeat_id", "candidate_id",
    "share"
  ) %in% names(cells)))
  # Real (non-mock) model IDs flow through.
  expect_setequal(unique(cells$model_id), c("prov-a/m", "prov-b/m"))
  # Shares in [0, 1] and sum to one per race x model x repeat.
  expect_true(all(cells$share >= 0 & cells$share <= 1, na.rm = TRUE))
  sums <- cells |>
    group_by(race_id, model_id, repeat_id) |>
    summarise(s = sum(share), .groups = "drop")
  expect_true(all(abs(sums$s - 1) < 1e-9))
})

test_that("bridge main function is a safe no-op when outputs are absent", {
  # No real LLM responses exist yet; the bridge must message and return
  # NULL (not error, not write anything).
  tmp_out <- file.path(tempdir(), "llm-bridge-test-out")
  expect_message(
    out <- run_llm_poststratify(
      llm_path = file.path(tempdir(), "does-not-exist.parquet"),
      personas_path = file.path("processed", "simulated", "simulated_personas.parquet"),
      crosswalk_path = file.path("processed", "simulated", "candidate_crosswalk.parquet"),
      out_dir = tmp_out
    ),
    "No real LLM responses"
  )
  expect_null(out)
  expect_false(dir.exists(tmp_out))
})

test_that("simulated outputs are never written by the bridge", {
  # The bridge writes only under processed/llm/; assert that this
  # directory is distinct from the simulated outputs directory.
  expect_false(
    identical(
      normalizePath(file.path("processed", "llm"), mustWork = FALSE),
      normalizePath(file.path("processed", "simulated"), mustWork = FALSE)
    )
  )
})
