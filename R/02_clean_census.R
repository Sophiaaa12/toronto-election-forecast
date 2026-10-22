# 02_clean_census.R
# Clean 2021 Toronto ward Census data for the synthetic voter population frame.

library(readxl)
library(dplyr)
library(tidyr)
library(stringr)
library(readr)

census_path <- "raw/census/ward_profiles_2021.xlsx"

# Read the 2021 One Variable worksheet
census <- read_excel(
  census_path,
  sheet = "2021 One Variable",
  col_names = FALSE
)

# Convert a Census block into long ward-level format
extract_block <- function(data, rows, header_row) {
  header <- unlist(
    data[header_row, ],
    use.names = FALSE
  )

  block <- data[rows, ]

  names(block) <- c(
    "category",
    header[2:27]
  )

  block |>
    pivot_longer(
      cols = -category,
      names_to = "geography",
      values_to = "count"
    ) |>
    filter(geography != "Toronto") |>
    mutate(
      ward = as.integer(
        str_remove(geography, "Ward ")
      ),
      count = as.numeric(count)
    ) |>
    select(
      ward,
      category,
      count
    )
}

# Extract five-year age groups from the Census
age_raw <- extract_block(
  data = census,
  rows = 20:38,
  header_row = 18
)

# Combine five-year age groups into four broader groups
age <- age_raw |>
  mutate(
    age_group = case_when(
      category %in% c(
        "20 to 24 years",
        "25 to 29 years"
      ) ~ "20-29",
      category %in% c(
        "30 to 34 years",
        "35 to 39 years",
        "40 to 44 years"
      ) ~ "30-44",
      category %in% c(
        "45 to 49 years",
        "50 to 54 years",
        "55 to 59 years",
        "60 to 64 years"
      ) ~ "45-64",
      category %in% c(
        "65 to 69 years",
        "70 to 74 years",
        "75 to 79 years",
        "80 to 84 years",
        "85 to 89 years",
        "90 years and over"
      ) ~ "65+",
      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(age_group)) |>
  group_by(
    ward,
    age_group
  ) |>
  summarise(
    count = sum(count, na.rm = TRUE),
    .groups = "drop"
  )

# Calculate age proportions among the population aged 20 and over
age <- age |>
  group_by(ward) |>
  mutate(
    population_20plus = sum(count),
    proportion = count / population_20plus
  ) |>
  ungroup() |>
  mutate(
    age_group = factor(
      age_group,
      levels = c(
        "20-29",
        "30-44",
        "45-64",
        "65+"
      )
    )
  ) |>
  arrange(
    ward,
    age_group
  ) |>
  mutate(
    age_group = as.character(age_group)
  )

# Extract mutually exclusive education categories
education_raw <- extract_block(
  data = census,
  rows = c(
    998,
    999,
    1001,
    1007
  ),
  header_row = 996
)

# Combine education categories into three broader groups
education <- education_raw |>
  mutate(
    education_group = case_when(
      category %in% c(
        "No certificate, diploma or degree",
        "High (secondary) school diploma or equivalency certificate"
      ) ~ "High school or less",
      category ==
        "Postsecondary certificate or diploma below bachelor level" ~
        "Postsecondary below bachelor's",
      category ==
        "Bachelor’s degree or higher" ~
        "Bachelor's degree or higher",
      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(education_group)) |>
  group_by(
    ward,
    education_group
  ) |>
  summarise(
    count = sum(count, na.rm = TRUE),
    .groups = "drop"
  )

# Calculate education proportions within each ward
education <- education |>
  group_by(ward) |>
  mutate(
    education_population = sum(count),
    proportion = count / education_population
  ) |>
  ungroup() |>
  mutate(
    education_group = factor(
      education_group,
      levels = c(
        "High school or less",
        "Postsecondary below bachelor's",
        "Bachelor's degree or higher"
      )
    )
  ) |>
  arrange(
    ward,
    education_group
  ) |>
  mutate(
    education_group = as.character(education_group)
  )

# Extract total Census population for each ward
population <- extract_block(
  data = census,
  rows = 19,
  header_row = 18
) |>
  rename(
    total_population = count
  ) |>
  select(
    ward,
    total_population
  )

# Add the population aged 20 and over
population_20plus <- age |>
  distinct(
    ward,
    population_20plus
  )

population <- population |>
  left_join(
    population_20plus,
    by = "ward"
  )

# Check that all 25 wards are represented
stopifnot(
  n_distinct(age$ward) == 25,
  n_distinct(education$ward) == 25,
  n_distinct(population$ward) == 25
)

# Check that every ward has four age groups
age_groups_per_ward <- age |>
  count(ward)

stopifnot(
  all(age_groups_per_ward$n == 4)
)

# Check that every ward has three education groups
education_groups_per_ward <- education |>
  count(ward)

stopifnot(
  all(education_groups_per_ward$n == 3)
)

# Check that age proportions sum to one within each ward
age_check <- age |>
  group_by(ward) |>
  summarise(
    total = sum(proportion),
    .groups = "drop"
  )

stopifnot(
  all(abs(age_check$total - 1) < 1e-8)
)

# Check that education proportions sum to one within each ward
education_check <- education |>
  group_by(ward) |>
  summarise(
    total = sum(proportion),
    .groups = "drop"
  )

stopifnot(
  all(abs(education_check$total - 1) < 1e-8)
)

# Save cleaned Census datasets
write_csv(
  age,
  "processed/census_age.csv"
)

write_csv(
  education,
  "processed/census_education.csv"
)

write_csv(
  population,
  "processed/ward_population.csv"
)
