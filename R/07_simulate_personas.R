# 07_simulate_personas.R
#
# Generate simulated voter personas from the 300-cell Census population
# frame using stratified sampling.
#
# Sampling design (see R/simulation_helpers.R for the full documentation):
#
#   - strata are the 300 population cells (25 wards x 4 age x 3 education);
#   - allocation per cell is proportional to the cell's share of the
#     citywide 20+ population, with a floor so every cell has positive
#     representation;
#   - each persona in cell c receives sampling weight w_c / n_c, so
#     weights sum to 1 citywide and ward-level weight totals equal each
#     ward's share of the 20+ population (citywide mayoral estimates are
#     therefore automatically weighted by ward population).
#
# Output: processed/simulated/simulated_personas.parquet
#
# No LLM APIs are used. The allocation is deterministic; a fixed seed is
# declared for pipeline consistency.

library(dplyr)
library(tidyr)
library(readr)
library(nanoparquet)

source(file.path("R", "simulation_helpers.R"))

message("==> 07: Simulating personas from the population frame")

pop_frame <- read_csv(
  "processed/population_frame.csv",
  show_col_types = FALSE
)

allocation <- allocate_population_cells(pop_frame) |>
  mutate(sampling_weight = cell_prop_citywide / n_personas)

personas <- allocation |>
  select(
    population_cell_id = cell_id,
    ward,
    age_group,
    education_group,
    sampling_weight,
    n_personas
  ) |>
  uncount(n_personas) |>
  mutate(persona_id = sprintf("P%06d", row_number())) |>
  select(
    persona_id,
    ward,
    age_group,
    education_group,
    population_cell_id,
    sampling_weight
  )

# Validation guards (fail loudly rather than write a bad frame).
stopifnot(
  n_distinct(personas$ward) == 25,
  n_distinct(personas$population_cell_id) == 300,
  all(allocation$n_personas >= PERSONA_MIN_PER_CELL),
  abs(sum(personas$sampling_weight) - 1) < 1e-9
)

dir.create(file.path("processed", "simulated"), showWarnings = FALSE)

write_parquet(
  personas,
  file.path("processed", "simulated", "simulated_personas.parquet")
)

message(
  sprintf(
    "    %d personas across %d cells; weights sum to %.6f",
    nrow(personas),
    n_distinct(personas$population_cell_id),
    sum(personas$sampling_weight)
  )
)
