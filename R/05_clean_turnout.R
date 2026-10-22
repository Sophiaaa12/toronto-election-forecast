# 05_clean_turnout.R
# Clean 2022 Toronto voter turnout data at the ward level.

library(readxl)
library(dplyr)
library(readr)

turnout_path <- "data/01-raw_data/elections/turnout_2022.xlsx"

# Read the 2022 turnout data
turnout_raw <- read_excel(
  turnout_path,
  sheet = "2022 Voter Turnout Statistics"
)

# Keep the variables needed for ward-level turnout
turnout <- turnout_raw |>
  transmute(
    ward = as.integer(Ward),
    eligible_electors = parse_number(
      as.character(`Total Eligible Electors`)
    ),
    ballots_cast = parse_number(
      as.character(`Number Voted`)
    )
  ) |>
  filter(
    ward %in% 1:25
  )

# Aggregate voting subdivisions to wards
turnout_by_ward <- turnout |>
  group_by(ward) |>
  summarise(
    eligible_electors = sum(
      eligible_electors,
      na.rm = TRUE
    ),
    ballots_cast = sum(
      ballots_cast,
      na.rm = TRUE
    ),
    .groups = "drop"
  ) |>
  mutate(
    turnout = ballots_cast / eligible_electors
  ) |>
  arrange(ward)

# Check that all 25 wards are represented
stopifnot(
  n_distinct(turnout_by_ward$ward) == 25,
  all(turnout_by_ward$ward == 1:25)
)

# Check turnout values
stopifnot(
  all(turnout_by_ward$eligible_electors > 0),
  all(turnout_by_ward$ballots_cast >= 0),
  all(turnout_by_ward$turnout >= 0),
  all(turnout_by_ward$turnout <= 1)
)

# Save cleaned turnout data
write_csv(
  turnout_by_ward,
  "processed/turnout_by_ward.csv"
)
