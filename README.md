# Toronto 2026 Election Data Pack

Goal: forecast the Toronto mayoral election and all 25 ward councillor elections on October 26, 2026.
Downloaded: October 7, 2026. No GitHub repository has been created and no LLM polling has been run.

## Ready to create a repository

The core raw data are available. This raw-data starter pack includes scripts, original files, official metadata, SHA256 checksums, and a source manifest. The processed directory contains only .gitkeep; no generated CSVs or validation report are included.
All 14 selected files downloaded successfully. Coverage: 53 active mayoral candidates, 190 active councillor candidates, 25 wards, and 25 map features.

## Core data and selection rationale

| File | Source website | Selection rationale and use |
|---|---|---|
| 2023-wardprofiles-2011-2021-censusdata_rev0719.xlsx | https://open.toronto.ca/dataset/ward-profiles-25-ward-model/ | Official Census workbook for the 25-ward model. Use the 2021 sheets for population marginals and available cross-tabulations. The filename's 2023 refers to publication, not the forecast year. |
| 2023-wardprofiles-geographicareas.xlsx | https://open.toronto.ca/dataset/ward-profiles-25-ward-model/ | Ward areas and geographic checks; supporting information rather than a voting predictor. |
| 25-wardnames-numbers.xlsx | https://open.toronto.ca/dataset/ward-profiles-25-ward-model/ | Official ward number/name lookup for consistent join keys. |
| mayorCandidates_2026.json | https://www.toronto.ca/city-government/elections/candidate-list/ | Valid 2026 mayoral choices; retain all 53 candidates and prevent the model from inventing names. |
| councilorCandidates_2026.json | https://www.toronto.ca/city-government/elections/candidate-list/ | Valid 2026 councillor choices, covering 190 candidates. Each ward must use its own candidate list. |
| withdrawnCandidates_2026.json | https://www.toronto.ca/city-government/elections/candidate-list/ | Check withdrawals to avoid outdated choices. Includes other offices; filter to mayor and councillor. |
| ward-and-elected-councillor-4326.geojson | https://open.toronto.ca/dataset/wards-and-elected-councillors/ | Boundaries for all 25 wards, suitable for website maps and geographic validation. |
| 2022-2026-elected-officials-contact-info.json | https://open.toronto.ca/dataset/elected-officials-contact-information/ | Officials for the current 2022–2026 term, used to check incumbency. The filename indicates the term, not a 2022 candidate list. |

Population data documentation: https://www.toronto.ca/city-government/data-research-maps/neighbourhoods-communities/ward-profiles/

## Optional historical references

These files are stored separately in `raw/historical_optional`.

| File | Source website | Selection rationale |
|---|---|---|
| 2022-results.zip | https://open.toronto.ca/dataset/election-results-official/ | Previous general-election mayoral and councillor vote counts for optional baseline/context. These are not 2026 outcomes. The original ZIP also contains school-board results, which can be ignored. |
| 2022_voter_turnout_statistics_final.xlsx | https://open.toronto.ca/dataset/elections-voter-statistics/ | Historical ward turnout, helping distinguish resident population from actual voters. Turnout for 2026 still requires assumptions. |
| 2023_office_of_the_mayor.xlsx | https://open.toronto.ca/dataset/elections-official-by-election-results/ | More recent mayoral by-election results for an optional baseline; not automatically blended with synthetic votes. |
| 2023-office-of-the-councillor-ward-20-poll-by-poll.xlsx | https://open.toronto.ca/dataset/elections-official-by-election-results/ | By-election reference to avoid assuming that a 2022 winner remains the incumbent in 2026. |
| 2024-councillor-ward-15-poll-by-poll.xlsx | https://open.toronto.ca/dataset/elections-official-by-election-results/ | Same purpose for Ward 15. |
| 2025-councillor-ward25-poll-by-poll.xlsx | https://open.toronto.ca/dataset/elections-official-by-election-results/ | Same purpose for Ward 25. |

## File structure and reproducibility

- `raw/core`: unmodified core source files.
- `raw/historical_optional`: optional historical files.
- `raw/*_metadata.json`: official dataset metadata and licence information captured at download time.
- `processed/candidates_2026.csv`: candidate name, office, ward, status, website, and preliminary incumbent exact-name match; excludes contact details.
- `processed/wards.csv`: official ward lookup.
- `processed/census_2021_*.csv`: direct conversions of the two 2021 worksheets, retaining explanatory rows; these are not cleaned modelling tables.
- `sources.json`: source website, direct download URL, download time, byte count, and SHA256 for each file.
- `validation.json`: coverage checks generated when you run `prepare_data.py`; not included in this starter pack.
- `download_data.py`: download again using the Python standard library. A new download may retrieve updated data; use this snapshot for exact reproducibility.
- `prepare_data.py`: JSON/Excel conversion, requiring `openpyxl` (available in the environment used to prepare this pack).

## Generate processed data after creating your repository (python version)

Run these commands from the directory containing `prepare_data.py` and `raw/`:

```bash
uv run --with openpyxl python prepare_data.py
```

The raw files are already downloaded. You do not need to run `download_data.py` to generate processed data. Run it only if you deliberately want to refresh the source snapshot; it requires internet access and may overwrite the downloaded files and source manifest.

`prepare_data.py` creates:

| Output | Raw inputs | Transformation |
|---|---|---|
| `processed/candidates_2026.csv` | Mayoral and councillor candidate JSON files, plus elected officials JSON | Flatten candidate records; add preliminary incumbent exact-name matches and website links. |
| `processed/wards.csv` | `25-wardnames-numbers.xlsx` | Export the active worksheet to CSV. |
| `processed/census_2021_one_variable.csv` | Census workbook, `2021 One Variable` worksheet | Export worksheet values, retaining explanatory rows. |
| `processed/census_2021_two_variable.csv` | Census workbook, `2021 Two Variable` worksheet | Export worksheet values, retaining explanatory rows. |
| `validation.json` | Candidate records, ward map, and `sources.json` | Record candidate counts, ward coverage, map feature count, and download failures. |

The script reads source files without modifying them. These CSVs are initial conversions, not final cleaned modelling data. Historical files, withdrawn candidates, geographic areas, and source-page snapshots remain available as references and are not converted by this script.

The candidate-count assertions are specific to this October 7, 2026 snapshot. Review them if you refresh the downloads and the official list changes.

Git does not track empty directories; `processed/.gitkeep` preserves this folder when you create the repository. You can remove it once CSVs have been generated.


## Generate processed data after creating your repository (R version)

Copy `prepare_data.R` and `download_data.R` into the project directory containing `raw/`, `processed/`, and `sources.json`. Open your RStudio project so the working directory is that directory.

Install dependencies once in the R console:

```r
install.packages(c("jsonlite", "readxl", "digest"))
```

The raw data are already downloaded. Generate the initial processed tables with:

```r
source("prepare_data.R")
```

Outputs: `processed/candidates_2026.csv`, `processed/wards.csv`, `processed/census_2021_one_variable.csv`, `processed/census_2021_two_variable.csv`, and `validation.json`.

Only to deliberately refresh the raw data, run:

```r
source("download_data.R")
source("prepare_data.R")
```

Refreshing requires internet access and overwrites source files and the source manifest. The download script retrieves the same resource types as the Python version; manually saved source-page HTML files are not refreshed.

The preparation script does not modify raw data. It uses explicit 2021 worksheet names and exports mixed Excel cells as text to preserve labels. The generated CSVs serve the same purposes as the Python outputs, but quoting, boolean spelling, numeric formatting, and leading/trailing blank worksheet margins may differ. They are initial conversions, not final cleaned modelling data.

Incumbent matches use lowercase exact names and require manual review. The validation counts are specific to the supplied October 7, 2026 snapshot.

These scripts replace the two Python scripts; you do not need to run both language versions. No processed files are included in this archive.

Validation limitation: the delivery environment did not provide an R runtime, so the scripts were reviewed against the supplied JSON structures and Excel worksheet names but were not executed in R.


## Work required after repository creation

1. Preserve the raw snapshot, sources, licences, and attribution. Use Toronto Open Data files under the licences recorded in metadata; separately check the terms for candidate-website JSON.
2. Audit Census variables and denominators. Age tables include minors; education covers ages 15+; income and tenure use household units. These cannot simply be combined into one eligible-voter distribution.
3. Document coverage of adult citizens and eligible non-resident property owners, among other municipal eligibility considerations. Census residents, eligible voters, and actual voters are different populations.
4. The two-variable sheet primarily contains housing-related cross-tabulations. It does not establish a complete age × gender × education × income × tenure joint distribution. If using raking with marginal data, disclose seed-distribution assumptions.
5. Verify incumbent name matches; exact matches in the CSV are preliminary indicators.
6. Collect consistent, sourced 2026 candidate policy and biography summaries with an information cutoff date. Only candidate lists and official website links are currently saved; full platforms have not been downloaded. Names alone can introduce model-knowledge and name-recognition bias.
7. Design synthetic sampling, prompts, LLM costs, and caching before modelling. A total of 25,000 personas is not yet a fixed decision.
8. Aggregate mayoral estimates using electorate/turnout weights rather than equal ward weights. LLM self-reported confidence is not a calibrated winning probability.
9. Distinguish simulation randomness from methodological bias. Bootstrapping synthetic responses alone does not capture real forecast error.

The 2026 election has not yet occurred, and this pack contains no 2026 election outcomes. The data are sufficient to begin repository creation and cleaning, but do not yet establish a reliable forecast.
