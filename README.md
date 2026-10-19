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
│   ├── 10_llm_poststratify.R
│   ├── run_pipeline.R
│   └── simulation_helpers.R
├── llm/
│   ├── __init__.py
│   ├── cache.py            # SHA-256 disk response cache
│   ├── client.py           # OpenRouter client (retries, backoff)
│   ├── config.py           # model config + API key handling
│   ├── cost.py             # cost log + budget enforcement
│   ├── models.example.json # template (placeholder model IDs)
│   ├── prompts.py          # persona prompt construction
│   ├── runner.py           # CLI: python3 -m llm.runner
│   └── schema.py           # strict JSON response validation
├── tests/
│   ├── run_tests.R
│   ├── python/             # mocked-HTTP unittest suite
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

## Real LLM Sampling (completed)

> **Status: production silicon sampling is COMPLETE and committed.**
> 36,504 production responses (3,042 personas × 26 races × 2 models × 3
> repeats) live in `processed/production/llm_responses.parquet`
> (md5 `420c3051da6c9a291f5fcf7b587e06bf`, protected by an md5 guard in
> `R/10_llm_poststratify.R`). Production spend was **US$3.1631**;
> cumulative spend across the pilot, diagnostic and production runs was
> **US$3.2004** of a $3.75 budget. Final forecasts are in
> `processed/forecast/` (Method C, target SD 4pp; 22/22 validation checks
> pass — see `processed/forecast/validation_report.md`). Reproducing the
> published figures and website does **not** require any API access.

The `llm/` Python package implements the OpenRouter integration that will
replace the mock providers in `R/08_simulate_llm_responses.R`. It reuses the
existing persona dataset, candidate crosswalk, and post-stratification
statistics unchanged; only the response *source* differs.

### API setup

The API key is read **only** from the `OPENROUTER_API_KEY` environment
variable. It is never written to source code, configuration files, or any
output artifact.

```sh
pip install -r llm/requirements.txt     # requests, pyarrow
export OPENROUTER_API_KEY=sk-or-...     # never commit this key
```

### Model configuration

Model entries live in `llm/models.json` (git-ignored). Start from the
committed template:

```sh
cp llm/models.example.json llm/models.json
# then edit llm/models.json with VERIFIED model IDs
```

The template's `example-org-*/example-model` IDs are **placeholders**. The
assignment forbids hardcoding unverified model IDs, so execution mode refuses
placeholder IDs by design; dry-run mode permits them. Select real model IDs
from <https://openrouter.ai/models> and record at least **two entries with
distinct providers** (the forecast design compares provider arms).

Each entry records: `model_id`, `provider`, `model_version` (optional pin),
`temperature`, `max_tokens`, `prompt_version`, `timeout_seconds`,
`max_retries`. Every one of these is stored in the request metadata, the cache
key, and the output Parquet for audit.

### Dry-run command

Dry-run plans requests, builds prompts, validates candidate lists, estimates
request counts and cost, and previews prompts — **without an API key and
without any HTTP requests**:

```sh
python3 -m llm.runner run --dry-run \
  --max-personas 3 --repeats 2 --preview 2 \
  --budget-usd 1.0 \
  --price-input-per-mtok 0.5 --price-output-per-mtok 1.5
```

Request count = `personas × 2 races × models × repeats` (each persona answers
the mayoral race and their own ward race). Supported flags: `--dry-run`,
`--max-personas`, `--max-requests`, `--models`, `--repeats`, `--budget-usd`,
`--config`, `--order`, `--seed`, `--refresh-cache`, `--preview`.

### What the LLM receives

Each request gives the model only: the persona's ward number, age group, and
education group; the race; and the candidate list (candidate_id + ballot
display name) for that one race. It does **not** receive sampling weights,
cell IDs, other personas, policy positions, biographies, or historical
results. Candidate ordering is configurable (`--order ballot|random|id`) and
reproducible via `--seed`.

### Caching mechanism

Responses are cached on local disk under `processed/llm_cache/` (git-ignored).
The cache key is a SHA-256 over: model ID, provider, model version,
temperature, max tokens, prompt version, candidate order + order seed, persona
ID, race ID, repeat ID, and the digest of the full rendered prompt. Repeated
runs of the same planned request reuse the cached response (no credits
spent). Different `repeat_id`s hash to different keys, so repeats are
independent requests, never copies. Only successful model answers
(`valid_choice`/`undecided`/`not_voting`) are cached as successes; technical
failures are recorded separately and re-attempted on later runs.

```sh
python3 -m llm.runner cache --list          # inspect cached successes
python3 -m llm.runner cache --list-failures # inspect recorded failures
python3 -m llm.runner cache --invalidate-model <model_id>
python3 -m llm.runner cache --invalidate-all
```

Manual invalidation also works: delete files under
`processed/llm_cache/success/`.

### Cost tracking

Every submitted request appends one JSON line to
`processed/llm/cost_log.jsonl` recording: model ID, provider, prompt version,
persona/race/repeat, request status, HTTP status, input tokens, output tokens,
prompt-cache tokens (if reported), actual USD cost (if reported by the API),
an estimate from an optional price table, timestamp, attempts, and elapsed
time.

**Actual and estimated costs are reported separately and never summed.**
Actual cost comes from the API response when OpenRouter reports it; prices are
never assumed fixed. Pre-run estimates use the optional
`--price-input-per-mtok` / `--price-output-per-mtok` flags (check current
prices on the OpenRouter model page at run time).

`--budget-usd` halts submission of new requests once cumulative spend reaches
the threshold (reported cost plus estimates for unreported-cost requests —
conservative). Spend is re-loaded from the cost log on every run, so a
resumed run still respects the budget. The run stops cleanly and reports how
far it got.

### Rate-limit and error behaviour

- HTTP 429, 5xx, timeouts, and connection errors: retried with exponential
  backoff and jitter (honouring `Retry-After`), up to `max_retries`.
- HTTP 400/401/402/403/404/422: **permanent** — not retried (retrying an
  invalid request cannot help).
- Retries exhausted: recorded as `timeout`, `rate_limit`, or `api_error`.
- Malformed JSON, missing fields, or a candidate_id outside the race's list:
  recorded as `invalid`.
- Successful HTTP but empty content: recorded as `missing`.

Model answers (`valid_choice`/`undecided`/`not_voting`) are always kept
distinct from technical failures (`missing`/`invalid`/`timeout`/`rate_limit`/
`api_error`). Failed requests are never cached as successes.

### Output schemas

`processed/llm_responses.parquet` — schema-compatible with the simulated
pipeline's response file, plus audit columns:

| field | notes |
|---|---|
| `persona_id`, `ward`, `race_id`, `candidate_id` | candidate_id is NULL unless `valid_choice` |
| `provider_id`, `model_id`, `repeat_id`, `response_status` | core simulation columns |
| `model_version`, `prompt_version`, `temperature`, `max_tokens` | request configuration |
| `candidate_order`, `n_candidates_in_race` | prompt construction audit |
| `http_status`, `attempts`, `elapsed_seconds`, `from_cache`, `cache_digest` | transport audit |
| `request_ts_utc`, `input_tokens`, `output_tokens`, `cached_tokens_reported` | usage audit |
| `cost_usd_actual`, `cost_usd_estimate`, `cost_source`, `detail` | cost + failure detail |

Raw API responses and request metadata are written to
`processed/llm/raw_requests/` (git-ignored). The cost log and run summary live
under `processed/llm/`. No credentials are stored in any output.

### Feeding real responses into the forecast

The production run's response Parquet is converted to forecasts with the
unchanged post-stratification statistics:

```sh
Rscript R/10_llm_poststratify.R processed/production/llm_responses.parquet centered
```

This validates the response file (schema, statuses, candidate–race matching,
persona coverage, frozen md5) and writes provider-specific forecasts,
descriptive pooled points, sensitivity runs and a validation report to
`processed/forecast/` — never overwriting `processed/simulated/`.

### Reproducibility (real sampling)

- The mocked test suite (`python3 -m unittest discover -s tests/python`)
  covers valid/invalid/undecided/not_voting responses, malformed JSON,
  missing fields, timeouts, rate limits, retry limits, caching, repeat
  independence, budget enforcement, and ward-candidate matching — **no test
  contacts OpenRouter**.
- R bridge tests (`tests/testthat/test-10_llm_bridge.R`) validate the
  response schema and confirm the post-stratification glue.
- For a real run: pin `model_version` and `prompt_version` in
  `llm/models.json`, keep `--seed` fixed, and archive `cost_log.jsonl` and
  `run_summary.json` alongside the outputs.

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

## Final Status

The full workflow is complete end-to-end:

1. an explicitly approved OpenRouter pilot validated the real client
   behaviour against the mocked test suite;
2. the full production response set (36,504 requests, $3.1631) was collected
   through the cached, budget-tracked pipeline and frozen with an md5 guard;
3. forecasts for the mayor and all 25 wards were produced with
   `R/10_llm_poststratify.R` (Method C, target SD 4pp; 22/22 validation
   checks; sensitivity grid 0.02/0.04/0.06);
4. the results are communicated through the Quarto website in `website/`,
   reproducible with `Rscript website/make_figures.R` followed by
   `quarto render website` (no API access required).

Diagnostic experiments (candidate-order sensitivity, mode collapse,
provider undecided rates) are committed under `processed/diagnostic/` and
reported in `docs/llm_diagnostic_report.md`.

## Website and GitHub Pages deployment

The assignment website lives in `website/` and renders to `website/_site/`.
The planned GitHub Pages deployment (not yet executed) is:

```sh
# one-time: push the project branch to GitHub, then
quarto publish gh-pages website --no-prompt
# then in GitHub: Settings → Pages → Source: Deploy from a branch
#                → branch: gh-pages / root
```

The published site will be at
<https://sophiaaa12.github.io/toronto-election-forecast/>. Rendering the
site performs no API calls and modifies no data, so it is safe to re-render
in CI.

## AI-use declaration

An AI coding assistant (Anthropic Claude, via the OpenCode CLI) was used to
write and test code, build the pipeline, and draft documentation; the author
reviewed, validated and approved every change. The forecast data were
generated by the two declared LLM APIs (`google/gemini-2.5-flash-lite`,
`openai/gpt-4o-mini`) — that is the method under study — and every response
is retained in the committed production file for audit.

## Reproducibility

The repository separates raw source data from generated data and keeps the data preparation and analysis steps in reproducible R scripts.

Validation checks are included throughout the pipeline to verify ward coverage, demographic weights, candidate data, election results, and turnout calculations.