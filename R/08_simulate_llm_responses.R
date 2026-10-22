# 08_simulate_llm_responses.R
#
# Generate MOCK vote-choice responses for the mayoral race and each
# persona's own ward councillor race.
#
# IMPORTANT: No external LLM APIs are called and no API credits are
# spent. All responses come from the explicit seeded statistical model
# in R/simulation_helpers.R (simulate_llm_responses()), which simulates
# two placeholder providers ("mock-alpha", "mock-beta") queried three
# independent times per persona-race pair.
#
# Response statuses are exhaustive and mutually exclusive:
#   valid_choice, undecided, not_voting, missing, invalid
# Rows with missing/invalid responses are RETAINED with candidate_id =
# NA; they are never silently dropped.
#
# Candidate IDs use the deterministic scheme in build_candidate_crosswalk()
# (candidates_2026.csv has no official ID column):
#   mayor: MAYOR-001 ... ; councillors: W01-C01 ... (sorted by ballot name)
#
# Outputs:
#   processed/simulated/simulated_responses.parquet
#   processed/simulated/candidate_crosswalk.parquet
#
# Fixed seed: SIM_SEEDS$responses.

library(dplyr)
library(readr)
library(nanoparquet)

source(file.path("R", "simulation_helpers.R"))

message("==> 08: Simulating mock LLM responses (2 providers x 3 repeats)")

personas <- read_parquet(
  file.path("processed", "simulated", "simulated_personas.parquet")
)

candidates <- read_csv(
  "processed/candidates_2026.csv",
  show_col_types = FALSE
)

turnout_by_ward <- read_csv(
  "processed/turnout_by_ward.csv",
  show_col_types = FALSE
)

responses <- simulate_llm_responses(
  personas        = personas,
  candidates      = candidates,
  turnout_by_ward = turnout_by_ward,
  seed            = SIM_SEEDS$responses
)

crosswalk <- build_candidate_crosswalk(candidates)

# Validation guards.
expected_rows <- nrow(personas) * 2 * nrow(PROVIDER_MODELS) * N_REPEATS
stopifnot(
  n_distinct(responses$race_id) == 26,
  n_distinct(responses$ward) == 25,
  nrow(responses) == expected_rows,
  all(responses$response_status %in% RESPONSE_STATUSES),
  all(is.na(responses$candidate_id) ==
    (responses$response_status != "valid_choice"))
)

dir.create(file.path("processed", "simulated"), showWarnings = FALSE)

write_parquet(
  responses,
  file.path("processed", "simulated", "simulated_responses.parquet")
)

write_parquet(
  crosswalk,
  file.path("processed", "simulated", "candidate_crosswalk.parquet")
)

status_counts <- responses |>
  count(response_status, name = "n")

message(sprintf("    %d response rows across %d races", nrow(responses), 26))
for (i in seq_len(nrow(status_counts))) {
  message(
    sprintf(
      "      %-13s %7d (%.1f%%)",
      status_counts$response_status[i],
      status_counts$n[i],
      100 * status_counts$n[i] / nrow(responses)
    )
  )
}
