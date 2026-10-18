# Toronto 2026 Election Forecast

This project develops a synthetic-voter forecast for the 2026 Toronto municipal election.

The project will forecast:

- the citywide mayoral election;
- councillor elections in all 25 Toronto wards.

The analysis combines official City of Toronto data with synthetic voter responses generated using large language models (LLMs).

## Project Structure

```text
toronto-election-forecast/
├── raw/
│   ├── census/
│   ├── candidates/
│   ├── elections/
│   ├── geography/
│   └── incumbency/
├── processed/
├── R/
│   ├── 01_inspect_census.R
│   ├── 02_clean_census.R
│   ├── 03_inspect_elections.R
│   ├── 04_clean_historical_results.R
│   ├── 05_clean_turnout.R
│   ├── 06_build_population_frame.R
│   ├── 07_simulate_personas.R
│   ├── 08_simulate_llm_responses.R
│   ├── 09_poststratify_forecast.R
│   ├── run_pipeline.R
│   └── simulation_helpers.R
├── tests/
│   ├── run_tests.R
│   └── testthat/
├── download_data.R
├── prepare_data.R
├── sources.json
├── validation.json
└── toronto-election-forecast.Rproj
```

## Data

All core datasets come from official City of Toronto sources.

The project currently uses:

- 2021 Census ward profiles;
- official 2026 mayoral and councillor candidate lists;
- withdrawn candidate records;
- 2022 mayoral and councillor election results;
- 2023 mayoral by-election results;
- 2023 Ward 20 councillor by-election results;
- 2024 Ward 15 councillor by-election results;
- 2025 Ward 25 councillor by-election results;
- 2022 voter turnout statistics;
- Toronto ward boundaries and ward names;
- current elected officials for incumbent identification.

Source URLs and download metadata are recorded in `sources.json`.

## Processed Data

The current processed datasets are:

```text
processed/
├── candidates_2026.csv
├── wards.csv
├── census_age.csv
├── census_education.csv
├── ward_population.csv
├── historical_results.csv
├── turnout_by_ward.csv
└── population_frame.csv
```

### Census

The population frame currently uses four age groups:

- `20-29`
- `30-44`
- `45-64`
- `65+`

and three education groups:

- `High school or less`
- `Postsecondary below bachelor's`
- `Bachelor's degree or higher`

The Census does not provide the required age-by-education joint distribution. The current population frame therefore approximates the joint distribution within each ward using:

\[
P(Age, Education \mid Ward)
\approx
P(Age \mid Ward)P(Education \mid Ward)
\]

This produces 12 demographic cells per ward and 300 cells across the 25 wards.

### Historical Elections

`historical_results.csv` contains cleaned candidate-level vote counts and vote shares for the 2022 general election and the more recent Toronto by-elections.

### Turnout

`turnout_by_ward.csv` contains ward-level eligible electors, ballots cast, and turnout from the 2022 municipal election.

### Simulated Silicon Sampling Pipeline

The pipeline in `R/07`–`R/09` (driven by one command, `Rscript R/run_pipeline.R`) implements the full silicon-sampling workflow using **simulated** LLM responses. No external LLM APIs are called and no API credits are spent; every response comes from an explicit, seeded statistical model so the end-to-end process can be exercised and tested offline.

All simulated outputs are written to `processed/simulated/` and kept separate from real election data:

```text
processed/simulated/
├── simulated_personas.parquet
├── simulated_responses.parquet
├── candidate_crosswalk.parquet
├── simulated_forecast_draws.parquet
└── simulated_forecast_summary.parquet
```

#### Persona generation (R/07)

Stratified sampling over the 300 population cells (25 wards × 4 age × 3 education). Allocation per cell is proportional to the cell's share of the citywide 20+ population, with a floor so every cell has positive representation (no empty cells). Each persona in a cell receives sampling weight `w_cell / n_cell`, so weights sum to 1 citywide and each ward's total weight equals its share of the 20+ population. Citywide mayoral estimates are therefore automatically weighted by ward population; wards are never treated as equally sized.

#### Candidate IDs

`candidates_2026.csv` has no official candidate ID column, so IDs are assigned deterministically: candidates within each race are sorted by ballot name and numbered (`MAYOR-001`…, `W01-C01`…). A `race_id` is `mayor` or `ward_XX_councillor`, giving 26 races (1 mayoral + 25 councillor).

#### Mock responses (R/08)

Two placeholder providers (`mock-alpha`, `mock-beta`), each queried three independent times per persona-race pair. A seeded latent-utility (softmax) model generates choices using exchangeable candidate strengths, an incumbency log-odds bonus (the only real-world electoral signal used), candidate × age and candidate × education preference slopes, and a systematic per-provider framing bias. Persona turnout intent is drawn once per race using 2022 ward (or citywide) turnout.

Each response carries one of five exhaustive statuses: `valid_choice`, `undecided`, `not_voting`, `missing`, `invalid`. Rows with `missing`/`invalid` responses are **retained** (with `candidate_id = NA`) and never silently discarded.

#### Post-stratification (R/09)

Estimation target: each candidate's share of **valid (decided) first preferences** in the race's elector population, with every persona carrying its Census design weight:

```
share_k = Σ_i w_i · 1[choice_i = k] / Σ_i w_i
```

summed over valid-choice responses only. Undecided, non-voting, missing and invalid responses are excluded from both numerator and denominator. Cells where no persona gives a valid response contribute no weight; the estimate renormalises over responding cells. Ward races sum over that ward's personas; the mayoral race sums over all personas with citywide weights, so wards enter in proportion to their 20+ population.

#### Forecast distributions (R/09)

Illustrative Monte Carlo draws (500 per race) that explicitly separate three sources of variation:

1. **Model/provider variation** — each draw first resamples one of the 2 × 3 provider-repeat cells.
2. **Response sampling variability** — candidate shares are drawn from a Dirichlet distribution with concentration scaled by the Kish effective sample size.
3. **Assumed forecast uncertainty** — independent zero-mean Gaussian noise (3 percentage points) is added to each share, truncated at zero and renormalised.

These intervals are **illustrative simulation output, not calibrated election uncertainty**.

#### Reproducibility

All randomness uses the fixed seeds in `R/simulation_helpers.R`; repeated runs produce identical outputs. The automated test suite (`Rscript tests/run_tests.R`) validates ward/race/cell coverage, weight properties, candidate–race consistency, response-status handling, share properties, and forecast reproducibility.

## Reproduction

Open `toronto-election-forecast.Rproj` in RStudio.

Install the required packages:

```r
install.packages(c(
  "jsonlite",
  "digest",
  "readxl",
  "dplyr",
  "tidyr",
  "stringr",
  "readr",
  "purrr",
  "testthat",
  "nanoparquet"
))
```

Download the raw data:

```r
source("download_data.R")
```

Prepare the candidate and ward data:

```r
source("prepare_data.R")
```

Run the analysis scripts in order:

```r
source("R/01_inspect_census.R")
source("R/02_clean_census.R")
source("R/03_inspect_elections.R")
source("R/04_clean_historical_results.R")
source("R/05_clean_turnout.R")
source("R/06_build_population_frame.R")
```

Run the simulated silicon-sampling pipeline (personas, mock responses, post-stratification, forecast draws):

```sh
Rscript R/run_pipeline.R
```

Run the automated test suite:

```sh
Rscript tests/run_tests.R
```

The `raw/` directory contains downloaded source data, while `processed/` contains datasets generated by the analysis pipeline. Simulated pipeline outputs are written to `processed/simulated/` and kept separate from real election data.

## Next Steps

The full workflow (persona generation, response collection, post-stratification, forecast distributions, uncertainty quantification) is implemented and tested end-to-end using **simulated** LLM responses. The remaining work will:

1. connect the response stage to two real LLM providers (replacing the mock providers, using the same response schema);
2. validate simulated-stage behaviour against real provider outputs;
3. publish the final results through a reproducible Quarto website.

## Reproducibility

The repository separates raw source data from generated data and keeps the data preparation and analysis steps in reproducible R scripts.

Validation checks are included throughout the pipeline to verify ward coverage, demographic weights, candidate data, election results, and turnout calculations.