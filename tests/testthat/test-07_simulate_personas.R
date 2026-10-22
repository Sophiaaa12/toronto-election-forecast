# test-07_simulate_personas.R
#
# Validates the simulated persona sampling design produced by
# R/07_simulate_personas.R.
#
# Coverage (required test categories):
#   - Exactly 25 wards represented
#   - All expected demographic cells represented (300 cells, positive
#     representation in every cell)
#   - Population weights sum to one
#   - Citywide mayoral weights reflect ward populations

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

# Rebuild the simulated personas from the population frame
source(file.path("R", "07_simulate_personas.R"))

personas <- read_parquet(
  file.path("processed", "simulated", "simulated_personas.parquet")
)

pop_frame <- read.csv("processed/population_frame.csv")
ward_pop <- read.csv("processed/ward_population.csv")

test_that("personas have the required schema", {
  expect_true(all(
    c(
      "persona_id", "ward", "age_group", "education_group",
      "population_cell_id", "sampling_weight"
    ) %in% names(personas)
  ))
  expect_equal(anyDuplicated(personas$persona_id), 0)
})

test_that("exactly 25 wards are represented", {
  expect_equal(n_distinct(personas$ward), 25)
  expect_equal(sort(unique(personas$ward)), 1:25)
})

test_that("all 300 demographic cells are represented with positive counts", {
  # 25 wards x 4 age groups x 3 education groups
  expect_equal(n_distinct(pop_frame$cell_id), 300)
  expect_equal(n_distinct(personas$population_cell_id), 300)

  per_cell <- personas |>
    count(population_cell_id, name = "n")

  # Every cell has at least one persona (no empty cells).
  expect_equal(nrow(per_cell), 300)
  expect_true(all(per_cell$n >= 1))
})

test_that("population weights sum to one", {
  expect_equal(sum(personas$sampling_weight), 1, tolerance = 1e-9)
  expect_true(all(personas$sampling_weight > 0))
})

test_that("citywide mayoral weights reflect ward populations", {
  # The sum of persona weights within each ward must equal that ward's
  # share of the citywide 20+ population. This is what makes the
  # citywide mayoral estimate population-weighted rather than treating
  # all 25 wards as equally sized.
  ward_weight <- personas |>
    group_by(ward) |>
    summarise(weight = sum(sampling_weight), .groups = "drop")

  ward_pop <- ward_pop |>
    mutate(expected = population_20plus / sum(population_20plus))

  cmp <- ward_weight |>
    inner_join(ward_pop, by = "ward")

  expect_equal(nrow(cmp), 25)
  expect_equal(cmp$weight, cmp$expected, tolerance = 1e-9)
})

test_that("persona generation is reproducible for a fixed allocation", {
  # The allocation is deterministic (no RNG); regenerating from the same
  # population frame must yield identical weights.
  source(file.path("R", "07_simulate_personas.R"))
  personas2 <- read_parquet(
    file.path("processed", "simulated", "simulated_personas.parquet")
  )
  expect_equal(personas$persona_id, personas2$persona_id)
  expect_equal(personas$sampling_weight, personas2$sampling_weight)
})
