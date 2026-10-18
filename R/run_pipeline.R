# run_pipeline.R
#
# One command to run the full simulated silicon-sampling pipeline.
#
# Usage (from the project root):
#
#   Rscript R/run_pipeline.R
#
# Stages:
#   07  simulate personas from the 300-cell population frame
#   08  simulate mock LLM responses (2 placeholder providers x 3 repeats)
#   09  post-stratify and generate Monte Carlo forecast draws
#
# All randomness uses the fixed seeds in R/simulation_helpers.R
# (SIM_SEEDS), so repeated runs produce byte-identical outputs.
#
# No external LLM APIs are called and no API credits are spent.

source(file.path("R", "07_simulate_personas.R"))
source(file.path("R", "08_simulate_llm_responses.R"))
source(file.path("R", "09_poststratify_forecast.R"))

message("==> Pipeline complete. Outputs in processed/simulated/")
