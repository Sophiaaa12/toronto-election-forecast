# test-08_simulate_llm_responses.R
#
# Validates the mock LLM responses produced by
# R/08_simulate_llm_responses.R.
#
# Coverage (required test categories):
#   - Exactly 25 wards represented
#   - Exactly 26 races represented
#   - Every candidate belongs to the correct race
#   - No invalid candidate IDs
#   - Valid handling of missing API responses (retained, not dropped)

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

# Ensure personas and responses are both rebuilt from source
source(file.path("R", "07_simulate_personas.R"))
source(file.path("R", "08_simulate_llm_responses.R"))

personas <- read_parquet(
  file.path("processed", "simulated", "simulated_personas.parquet")
)
responses <- read_parquet(
  file.path("processed", "simulated", "simulated_responses.parquet")
)
crosswalk <- read_parquet(
  file.path("processed", "simulated", "candidate_crosswalk.parquet")
)

test_that("responses have the required schema", {
  expect_true(all(
    c(
      "persona_id", "race_id", "candidate_id", "model_id",
      "repeat_id", "response_status"
    ) %in% names(responses)
  ))
})

test_that("exactly 25 wards and 26 races are represented", {
  expect_equal(n_distinct(responses$ward), 25)
  expect_equal(n_distinct(responses$race_id), 26)
  # One mayoral race + 25 ward councillor races
  expect_true("mayor" %in% responses$race_id)
  expect_equal(
    sum(grepl("^ward_[0-9]{2}_councillor$", unique(responses$race_id))),
    25
  )
})

test_that("both placeholder providers and three repeats are present", {
  expect_equal(n_distinct(responses$model_id), 2)
  expect_equal(sort(unique(responses$repeat_id)), 1:3)
  # Full factorial: every persona answers mayor + own ward, for each
  # provider x repeat.
  expect_equal(
    nrow(responses),
    nrow(personas) * 2 * 2 * 3
  )
})

test_that("every candidate belongs to the correct race", {
  # No valid_choice response may reference a candidate from another race.
  valid <- responses |>
    filter(response_status == "valid_choice") |>
    distinct(race_id, candidate_id)

  joined <- valid |>
    inner_join(
      crosswalk |> select(candidate_id, race_race = race_id, office, ward),
      by = "candidate_id"
    )

  expect_equal(nrow(joined), nrow(valid))
  expect_true(all(joined$race_id == joined$race_race))

  # Ward councillor candidates must belong to the ward named in race_id.
  ward_resp <- joined |>
    filter(office == "councillor")
  race_ward <- as.integer(sub("ward_([0-9]{2})_councillor", "\\1", ward_resp$race_id))
  expect_true(all(race_ward == ward_resp$ward))
})

test_that("no invalid candidate IDs appear in responses", {
  non_na <- responses |>
    filter(!is.na(candidate_id)) |>
    distinct(candidate_id)

  expect_true(all(non_na$candidate_id %in% crosswalk$candidate_id))
  expect_lte(nrow(non_na), nrow(crosswalk))
})

test_that("response statuses are exhaustive and missing rows are retained", {
  # All five statuses are used and every row carries exactly one.
  expect_true(all(responses$response_status %in%
    c(
      "valid_choice", "undecided", "not_voting",
      "missing", "invalid"
    )))
  expect_false(any(is.na(responses$response_status)))

  # Missing and invalid responses are RETAINED (not silently dropped).
  n_missing <- sum(responses$response_status == "missing")
  n_invalid <- sum(responses$response_status == "invalid")
  expect_gt(n_missing, 0)
  expect_gt(n_invalid, 0)

  # They carry NA candidate_id, and only valid_choice rows have one.
  expect_true(all(is.na(
    responses$candidate_id[responses$response_status %in%
      c(
        "missing", "invalid", "undecided",
        "not_voting"
      )]
  )))
  expect_false(any(is.na(
    responses$candidate_id[responses$response_status == "valid_choice"]
  )))
})

test_that("persona-race pairing is correct (own ward only)", {
  # Each persona answers the mayoral race plus exactly ONE councillor
  # race: the one for their own ward.
  per_persona <- responses |>
    distinct(persona_id, race_id) |>
    group_by(persona_id) |>
    summarise(n_races = n_distinct(race_id), .groups = "drop")

  expect_true(all(per_persona$n_races == 2))

  ward_races <- responses |>
    filter(race_id != "mayor") |>
    distinct(persona_id, ward, race_id)

  race_ward <- as.integer(
    sub("ward_([0-9]{2})_councillor", "\\1", ward_races$race_id)
  )
  expect_true(all(race_ward == ward_races$ward))
})

test_that("candidate ID scheme is deterministic and unique", {
  expect_equal(anyDuplicated(crosswalk$candidate_id), 0)
  expect_equal(
    sum(grepl("^MAYOR-[0-9]{3}$", crosswalk$candidate_id)),
    sum(crosswalk$office == "mayor")
  )
  # Crosswalk candidates all come from the official 2026 list.
  c26 <- read.csv("processed/candidates_2026.csv")
  expect_equal(nrow(crosswalk), sum(c26$status == "Active"))
})
