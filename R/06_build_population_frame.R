# 06_build_population_frame.R
# Build ward-level synthetic population cells from age and education margins.

library(dplyr)
library(readr)

# Read cleaned Census margins
age <- read_csv(
  "processed/census_age.csv",
  show_col_types = FALSE
)

education <- read_csv(
  "processed/census_education.csv",
  show_col_types = FALSE
)

# Keep variables needed for the population frame
age_margin <- age |>
  select(
    ward,
    age_group,
    age_proportion = proportion,
    population_20plus
  )

education_margin <- education |>
  select(
    ward,
    education_group,
    education_proportion = proportion
  )

# Create all age and education combinations within each ward
population_frame <- age_margin |>
  inner_join(
    education_margin,
    by = "ward"
  )

# Estimate each population cell under the independence assumption
population_frame <- population_frame |>
  mutate(
    cell_proportion =
      age_proportion *
      education_proportion,
    estimated_population =
      population_20plus *
      cell_proportion
  )

# Add stable identifiers for each population cell
population_frame <- population_frame |>
  mutate(
    age_code = case_when(
      age_group == "20-29" ~ "A1",
      age_group == "30-44" ~ "A2",
      age_group == "45-64" ~ "A3",
      age_group == "65+" ~ "A4"
    ),
    education_code = case_when(
      education_group == "High school or less" ~ "E1",
      education_group == "Postsecondary below bachelor's" ~ "E2",
      education_group == "Bachelor's degree or higher" ~ "E3"
    ),
    cell_id = paste0(
      "W",
      sprintf("%02d", ward),
      "_",
      age_code,
      "_",
      education_code
    )
  ) |>
  select(
    cell_id,
    ward,
    age_group,
    education_group,
    age_proportion,
    education_proportion,
    cell_proportion,
    population_20plus,
    estimated_population
  ) |>
  arrange(
    ward,
    age_group,
    education_group
  )

# Check that every ward has twelve population cells
cells_per_ward <- population_frame |>
  count(ward)

stopifnot(
  n_distinct(population_frame$ward) == 25,
  all(cells_per_ward$n == 12),
  nrow(population_frame) == 300
)

# Check that cell proportions sum to one within each ward
proportion_check <- population_frame |>
  group_by(ward) |>
  summarise(
    total = sum(cell_proportion),
    .groups = "drop"
  )

stopifnot(
  all(
    abs(proportion_check$total - 1) < 1e-8
  )
)

# Check that estimated cell populations recover the ward population
population_check <- population_frame |>
  group_by(ward) |>
  summarise(
    estimated_total = sum(estimated_population),
    population_20plus = first(population_20plus),
    .groups = "drop"
  )

stopifnot(
  all(
    abs(
      population_check$estimated_total -
        population_check$population_20plus
    ) < 1e-6
  )
)

# Save the synthetic population frame
write_csv(
  population_frame,
  "processed/population_frame.csv"
)