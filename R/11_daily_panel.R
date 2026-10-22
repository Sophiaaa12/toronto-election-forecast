# R/11_daily_panel.R
#
# Fixed persona panel for the daily tracker.
#
# Polling all 3,042 personas every day would cost roughly the full
# production run per day, so the tracker polls a FIXED stratified
# subsample: `per_cell` personas from each of the 300 census cells
# (default 4 -> 1,200 personas). The same panel is reused every day so
# day-to-day movement reflects the news context, not panel turnover.
#
# Weights are re-derived so post-stratification is unchanged: each
# panel persona carries its cell's population share divided by the
# number of panel personas in that cell, so weights still sum to 1
# citywide and to each ward's 20+ population share within a ward.
#
# Usage:
#   Rscript R/11_daily_panel.R [per_cell]
#
# Input:  processed/simulated/simulated_personas.parquet
# Output: processed/daily/panel_personas.parquet

library(dplyr)
library(nanoparquet)

DAILY_PANEL_SEED <- 20261020
DAILY_PANEL_PER_CELL <- 4L
DAILY_PANEL_PATH <- file.path("processed", "daily", "panel_personas.parquet")

build_daily_panel <- function(personas, per_cell = DAILY_PANEL_PER_CELL,
                              seed = DAILY_PANEL_SEED) {
  stopifnot(per_cell >= 1)
  cell_w <- personas |>
    group_by(population_cell_id) |>
    summarise(cell_weight = sum(sampling_weight), n_cell = n(), .groups = "drop")
  if (any(cell_w$n_cell < per_cell)) {
    stop(
      "per_cell = ", per_cell, " exceeds the smallest cell (",
      min(cell_w$n_cell), " personas)"
    )
  }

  set.seed(seed)
  personas |>
    arrange(population_cell_id, persona_id) |>
    group_by(population_cell_id) |>
    slice_sample(n = per_cell) |>
    ungroup() |>
    left_join(cell_w, by = "population_cell_id") |>
    mutate(
      sampling_weight = cell_weight / per_cell,
      ward = as.integer(ward)
    ) |>
    select(
      persona_id, ward, age_group, education_group,
      population_cell_id, sampling_weight
    ) |>
    arrange(persona_id)
}

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  per_cell <- if (length(args) >= 1) as.integer(args[1]) else DAILY_PANEL_PER_CELL
  personas <- read_parquet(file.path(
    "processed", "simulated",
    "simulated_personas.parquet"
  ))
  panel <- build_daily_panel(personas, per_cell = per_cell)
  stopifnot(
    n_distinct(panel$population_cell_id) == 300,
    abs(sum(panel$sampling_weight) - 1) < 1e-9
  )
  dir.create(dirname(DAILY_PANEL_PATH), showWarnings = FALSE, recursive = TRUE)
  write_parquet(panel, DAILY_PANEL_PATH)
  message(
    "Daily panel: ", nrow(panel), " personas (", per_cell,
    " per cell x 300 cells) -> ", DAILY_PANEL_PATH
  )
}
