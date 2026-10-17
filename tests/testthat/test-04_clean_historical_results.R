# test-04_clean_historical_results.R
#
# Regression tests for the historical election results pipeline.
#
# These tests source R/04_clean_historical_results.R (which rebuilds
# processed/historical_results.csv from raw data) and then validate
# the cleaned output.
#
# Key regression: every poll-by-poll workbook includes a trailing
# aggregate "Total" column that repeats the ward total. The previous
# version of clean_election_sheet() summed it together with the
# subdivision columns, doubling every candidate's votes (e.g. Ward 1
# 2022 mayoral total_valid_votes was 33024 instead of 16512).
#
# Reference values below are taken from the City of Toronto Clerk's
# official Declarations of Results:
# - 2022 Municipal General Election: Tory 342158
# - 2023 By-Election for Mayor: Chow 269372, citywide valid 724638
# - 2024 Ward 15 by-election: Chernos Lin 12899
# - 2025 Ward 25 by-election: Shan 5174, citywide valid 19260

library(testthat)
library(readr)
library(dplyr)

# Locate the project root so tests work when testthat sets the
# working directory to tests/testthat/
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
old_wd <- setwd(project_root)
on.exit(setwd(old_wd), add = TRUE)

# Rebuild the cleaned dataset from raw sources
source(file.path("R", "04_clean_historical_results.R"))

historical <- read_csv(
  "processed/historical_results.csv",
  show_col_types = FALSE
)

test_that("Ward 1 2022 mayoral total valid votes equal the official count", {
  ward_1_2022 <- historical |>
    filter(
      year == 2022,
      election_type == "general",
      office == "mayor",
      ward == 1
    )
  
  # 31 candidates official; total_valid_votes must be 16512, not the
  # doubled 33024 produced by the previous buggy aggregation.
  expect_equal(nrow(ward_1_2022), 31)
  expect_equal(unique(ward_1_2022$total_valid_votes), 16512)
  expect_equal(sum(ward_1_2022$votes), 16512)
})

test_that("aggregate Total columns are not double counted in any race", {
  # Each race's total_valid_votes must equal the sum of candidate votes
  race_totals <- historical |>
    group_by(year, election_type, office, ward) |>
    summarise(
      sum_votes = sum(votes),
      reported_total = first(total_valid_votes),
      .groups = "drop"
    )
  
  expect_true(all(race_totals$sum_votes == race_totals$reported_total))
  
  # Citywide mayoral totals pinned to the official declarations
  mayor_2022_total <- historical |>
    filter(year == 2022, office == "mayor") |>
    pull(votes) |>
    sum()
  expect_equal(mayor_2022_total, 551890)
  
  mayor_2023_total <- historical |>
    filter(
      year == 2023,
      office == "mayor",
      election_type == "by-election"
    ) |>
    pull(votes) |>
    sum()
  expect_equal(mayor_2023_total, 724638)
})

test_that("candidate votes are nonnegative integers", {
  expect_true(all(historical$votes >= 0))
  expect_true(all(historical$votes == floor(historical$votes)))
  expect_true(all(historical$total_valid_votes > 0))
})

test_that("vote shares are between zero and one", {
  expect_true(all(historical$vote_share >= 0))
  expect_true(all(historical$vote_share <= 1))
})

test_that("vote shares sum to one within each race", {
  share_totals <- historical |>
    group_by(year, election_type, office, ward) |>
    summarise(
      total = sum(vote_share),
      .groups = "drop"
    )
  
  expect_true(all(abs(share_totals$total - 1) < 1e-8))
})

test_that("no duplicated race-candidate records", {
  duplicates <- historical |>
    group_by(year, election_type, office, ward, candidate) |>
    summarise(n = n(), .groups = "drop") |>
    filter(n > 1)
  
  expect_equal(nrow(duplicates), 0)
})

test_that("all expected races are present", {
  races <- historical |>
    distinct(year, election_type, office)
  
  expect_equal(nrow(races), 6)
  
  # 25 wards per citywide race; exactly one ward per by-election race
  wards_by_race <- historical |>
    distinct(year, election_type, office, ward) |>
    count(year, election_type, office)
  
  expect_true(all(wards_by_race$n %in% c(1, 25)))
  
  expect_equal(
    historical |>
      filter(election_type == "by-election", office == "councillor") |>
      distinct(ward) |>
      nrow(),
    3
  )
})

test_that("results match official declarations of results", {
  # 2022 general: John Tory 342158 votes citywide
  tory <- historical |>
    filter(year == 2022, office == "mayor", grepl("Tory", candidate))
  expect_equal(sum(tory$votes), 342158)
  
  # 2022 general Ward 1 councillor: Crisanti 6815
  crisanti <- historical |>
    filter(
      year == 2022,
      election_type == "general",
      office == "councillor",
      ward == 1,
      grepl("Crisanti", candidate)
    )
  expect_equal(sum(crisanti$votes), 6815)
  
  # 2023 by-election: Olivia Chow 269372 votes citywide
  chow <- historical |>
    filter(year == 2023, office == "mayor", grepl("Chow", candidate))
  expect_equal(sum(chow$votes), 269372)
  
  # 2023 Ward 20 by-election: Kandavel elected; 16974 ballots cast,
  # of which 16950 valid votes in the poll-by-poll workbook
  ward_20 <- historical |>
    filter(
      year == 2023,
      election_type == "by-election",
      office == "councillor",
      ward == 20
    )
  expect_equal(unique(ward_20$total_valid_votes), 16950)
  expect_equal(ward_20$candidate[which.max(ward_20$votes)], "Kandavel Parthi")
  
  # 2024 Ward 15 by-election: Chernos Lin 12899, Furey 7343
  ward_15 <- historical |>
    filter(
      year == 2024,
      election_type == "by-election",
      office == "councillor",
      ward == 15
    )
  expect_equal(ward_15$votes[grepl("Chernos Lin", ward_15$candidate)], 12899)
  expect_equal(ward_15$votes[grepl("Furey", ward_15$candidate)], 7343)
  
  # 2025 Ward 25 by-election: Shan 5174; valid votes sum to 19260
  # (19284 ballots cast per the City Clerk's news release)
  ward_25 <- historical |>
    filter(
      year == 2025,
      election_type == "by-election",
      office == "councillor",
      ward == 25
    )
  expect_equal(unique(ward_25$total_valid_votes), 19260)
  expect_equal(ward_25$votes[grepl("Shan", ward_25$candidate)], 5174)
})
