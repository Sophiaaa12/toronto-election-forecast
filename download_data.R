# download_data.R
#
# Downloads only the raw data used in the Toronto 2026 election forecast.
# Run from the project root:
#
#   source("download_data.R")
#
# Required packages:
#   (requires the jsonlite and digest packages)

library(jsonlite)
library(digest)


# ------------------------------------------------------------
# 1. Create raw-data folders
# ------------------------------------------------------------

dirs <- c(
  "raw/census",
  "raw/candidates",
  "raw/elections",
  "raw/geography",
  "raw/incumbency"
)

for (dir in dirs) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
}


# ------------------------------------------------------------
# 2. Files used in the project
# ------------------------------------------------------------

files <- list(
  # ------------------------
  # Census
  # ------------------------
  list(
    file = "raw/census/ward_profiles_2021.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/6678e1a6-d25f-4dff-b2b7-aa8f042bc2eb/",
      "resource/16a31e1d-b4d9-4cf0-b5b3-2e3937cb4121/",
      "download/2023-wardprofiles-2011-2021-censusdata_rev0719.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/ward-profiles-25-ward-model/",
    purpose = "2021 ward-level Census data for population frame and post-stratification"
  ),


  # ------------------------
  # 2026 candidates
  # ------------------------

  list(
    file = "raw/candidates/mayor_candidates_2026.json",
    url = "https://www.toronto.ca/data/elections/candidate_list/mayorCandidates_2026.json",
    source = "https://www.toronto.ca/city-government/elections/candidate-list/",
    purpose = "Official 2026 mayor candidate list"
  ),
  list(
    file = "raw/candidates/councillor_candidates_2026.json",
    url = "https://www.toronto.ca/data/elections/candidate_list/councilorCandidates_2026.json",
    source = "https://www.toronto.ca/city-government/elections/candidate-list/",
    purpose = "Official 2026 councillor candidate lists by ward"
  ),
  list(
    file = "raw/candidates/withdrawn_candidates_2026.json",
    url = "https://www.toronto.ca/data/elections/candidate_list/withdrawnCandidates_2026.json",
    source = "https://www.toronto.ca/city-government/elections/candidate-list/",
    purpose = "Quality check for withdrawn candidates"
  ),


  # ------------------------
  # Historical elections
  # ------------------------

  list(
    file = "raw/elections/election_results_2022.zip",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/96d35404-44d9-49d8-95bb-fb1e5489240d/",
      "resource/3ad371de-7c51-45d3-9ea4-0b4efac5fc2b/",
      "download/2022-results.zip"
    ),
    source = "https://open.toronto.ca/dataset/election-results-official/",
    purpose = "2022 mayor and councillor historical election results"
  ),
  list(
    file = "raw/elections/turnout_2022.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/7dc606ab-f042-4d90-99e2-9247cb5953d2/",
      "resource/631b7042-bd71-46b1-9c27-2d4119462ec7/",
      "download/2022_voter_turnout_statistics_final.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/elections-voter-statistics/",
    purpose = "Ward-level electorate and turnout for weighting"
  ),
  list(
    file = "raw/elections/mayor_by_election_2023.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/97d72233-8681-4b3d-828e-4929d40d122c/",
      "resource/868f890d-5432-432b-823c-c6a6fafa2f63/",
      "download/2023_office_of_the_mayor.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/elections-official-by-election-results/",
    purpose = "Most recent citywide mayor election baseline"
  ),
  list(
    file = "raw/elections/ward20_by_election_2023.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/97d72233-8681-4b3d-828e-4929d40d122c/",
      "resource/5ced6a0b-1f7a-4717-b522-da02a4d916ab/",
      "download/2023-office-of-the-councillor-ward-20-poll-by-poll.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/elections-official-by-election-results/",
    purpose = "Updated historical councillor result for Ward 20"
  ),
  list(
    file = "raw/elections/ward15_by_election_2024.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/97d72233-8681-4b3d-828e-4929d40d122c/",
      "resource/7e64ea38-c3a4-4b1f-a68e-4127dfca6430/",
      "download/2024-councillor-ward-15-poll-by-poll.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/elections-official-by-election-results/",
    purpose = "Updated historical councillor result for Ward 15"
  ),
  list(
    file = "raw/elections/ward25_by_election_2025.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/97d72233-8681-4b3d-828e-4929d40d122c/",
      "resource/1a29cfb8-0ee8-4e7d-b415-f07963d5a436/",
      "download/2025-councillor-ward25-poll-by-poll.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/elections-official-by-election-results/",
    purpose = "Updated historical councillor result for Ward 25"
  ),


  # ------------------------
  # Geography
  # ------------------------

  list(
    file = "raw/geography/wards.geojson",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/a2a33cd7-877e-4b68-af54-dfe8a6b53170/",
      "resource/8d621291-bc8e-482c-ada4-e32c52d6dbdf/",
      "download/ward-and-elected-councillor-4326.geojson"
    ),
    source = "https://open.toronto.ca/dataset/wards-and-elected-councillors/",
    purpose = "Ward boundaries for maps and geographic validation"
  ),
  list(
    file = "raw/geography/ward_names.xlsx",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/6678e1a6-d25f-4dff-b2b7-aa8f042bc2eb/",
      "resource/ea4cc466-bd4d-40c6-a616-7abfa9d7398f/",
      "download/25-wardnames-numbers.xlsx"
    ),
    source = "https://open.toronto.ca/dataset/ward-profiles-25-ward-model/",
    purpose = "Official ward number and ward name lookup"
  ),


  # ------------------------
  # Incumbency
  # ------------------------

  list(
    file = "raw/incumbency/elected_officials_2022_2026.json",
    url = paste0(
      "https://ckan0.cf.opendata.inter.prod-toronto.ca/",
      "dataset/27aa4651-4548-4e57-bf00-53a346931251/",
      "resource/161c66b5-bcc8-4cb9-bbf8-4f44c837fa0f/",
      "download/2022-2026-elected-officials-contact-info.json"
    ),
    source = "https://open.toronto.ca/dataset/elected-officials-contact-information/",
    purpose = "Current elected officials used to identify incumbents"
  )
)


# ------------------------------------------------------------
# 3. Download files
# ------------------------------------------------------------

download_one <- function(x) {
  message("Downloading: ", x$file)

  status <- download.file(
    url = x$url,
    destfile = x$file,
    mode = "wb",
    quiet = FALSE
  )

  if (status != 0) {
    stop("Download failed: ", x$file)
  }

  x$bytes <- file.info(x$file)$size

  x$sha256 <- digest(
    file = x$file,
    algo = "sha256"
  )

  x$downloaded_at <- format(
    Sys.time(),
    "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )

  message("Saved: ", x$file)

  x
}


downloaded <- lapply(files, download_one)


# ------------------------------------------------------------
# 4. Save source manifest
# ------------------------------------------------------------

write_json(
  downloaded,
  path = "sources.json",
  pretty = TRUE,
  auto_unbox = TRUE
)

message("")
message("Finished downloading ", length(downloaded), " files.")
message("Source information saved to sources.json.")
