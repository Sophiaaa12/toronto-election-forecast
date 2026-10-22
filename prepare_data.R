# prepare_data.R
# Prepare shared project data and run basic validation checks.

library(jsonlite)
library(readxl)

# Create processed directory
dir.create(
  "processed",
  recursive = TRUE,
  showWarnings = FALSE
)

# Check required raw files
required_files <- c(
  "data/01-raw_data/census/ward_profiles_2021.xlsx",
  "data/01-raw_data/candidates/mayor_candidates_2026.json",
  "data/01-raw_data/candidates/councillor_candidates_2026.json",
  "data/01-raw_data/candidates/withdrawn_candidates_2026.json",
  "data/01-raw_data/elections/election_results_2022.zip",
  "data/01-raw_data/elections/turnout_2022.xlsx",
  "data/01-raw_data/elections/mayor_by_election_2023.xlsx",
  "data/01-raw_data/elections/ward20_by_election_2023.xlsx",
  "data/01-raw_data/elections/ward15_by_election_2024.xlsx",
  "data/01-raw_data/elections/ward25_by_election_2025.xlsx",
  "data/01-raw_data/geography/wards.geojson",
  "data/01-raw_data/geography/ward_names.xlsx",
  "data/01-raw_data/incumbency/elected_officials_2022_2026.json"
)

missing_files <- required_files[!file.exists(required_files)]

if (length(missing_files) > 0) {
  stop(
    paste(
      "Missing required raw files:",
      paste(missing_files, collapse = "\n")
    )
  )
}

message("All required raw files found.")

# Helper for reading JSON files
read_json_raw <- function(path) {
  jsonlite::fromJSON(
    path,
    simplifyVector = FALSE
  )
}

# Read current elected officials
officials <- read_json_raw(
  "data/01-raw_data/incumbency/elected_officials_2022_2026.json"
)

incumbents <- list()

for (person in officials) {
  role <- person[["Primary role"]]

  if (is.null(role)) {
    next
  }

  if (!role %in% c("Mayor", "Councillor")) {
    next
  }

  office <- if (role == "Mayor") {
    "mayor"
  } else {
    "councillor"
  }

  ward <- if (role == "Mayor") {
    0L
  } else {
    as.integer(person[["District ID"]])
  }

  full_name <- tolower(
    trimws(
      paste(
        person[["First name"]],
        person[["Last name"]]
      )
    )
  )

  incumbents[[paste(office, ward, sep = ":")]] <- full_name
}

# Prepare 2026 candidate lists
candidate_files <- c(
  mayor = "data/01-raw_data/candidates/mayor_candidates_2026.json",
  councillor = "data/01-raw_data/candidates/councillor_candidates_2026.json"
)

candidate_rows <- list()

for (office in names(candidate_files)) {
  candidate_data <- read_json_raw(
    candidate_files[[office]]
  )

  groups <- if (office == "mayor") {
    list(
      list(
        num = 0L,
        candidate = candidate_data$candidates
      )
    )
  } else {
    candidate_data$ward
  }

  for (group in groups) {
    ward <- as.integer(group$num)

    for (candidate in group$candidate) {
      display_name <- trimws(
        paste(
          candidate$firstName,
          candidate$lastName
        )
      )

      incumbent_name <- incumbents[[paste(office, ward, sep = ":")]]

      websites <- character(0)

      if (!is.null(candidate$socialMedias)) {
        websites <- vapply(
          Filter(
            function(x) identical(x$name, "web"),
            candidate$socialMedias
          ),
          function(x) x$url,
          character(1)
        )
      }

      candidate_rows[[length(candidate_rows) + 1]] <-
        data.frame(
          office = office,
          ward = ward,
          ballot_name = candidate$name,
          display_name = display_name,
          status = candidate$status,
          incumbent_name_match =
            !is.null(incumbent_name) &&
              identical(
                tolower(display_name),
                incumbent_name
              ),
          website = paste(
            websites,
            collapse = " | "
          ),
          stringsAsFactors = FALSE
        )
    }
  }
}

candidates <- do.call(
  rbind,
  candidate_rows
)

write.csv(
  candidates,
  "processed/candidates_2026.csv",
  row.names = FALSE,
  na = "",
  fileEncoding = "UTF-8"
)

message("Created: processed/candidates_2026.csv")

# Prepare ward lookup
wards <- read_excel(
  "data/01-raw_data/geography/ward_names.xlsx"
)

write.csv(
  wards,
  "processed/wards.csv",
  row.names = FALSE,
  na = "",
  fileEncoding = "UTF-8"
)

message("Created: processed/wards.csv")

# Check Census worksheets
census_sheets <- excel_sheets(
  "data/01-raw_data/census/ward_profiles_2021.xlsx"
)

required_census_sheets <- c(
  "2021 One Variable",
  "2021 Two Variable"
)

if (!all(required_census_sheets %in% census_sheets)) {
  stop(
    "Required 2021 Census worksheets were not found."
  )
}

# Validate candidates and geography
map_data <- read_json_raw(
  "data/01-raw_data/geography/wards.geojson"
)

validation <- list(
  mayor_candidates =
    sum(candidates$office == "mayor"),
  councillor_candidates =
    sum(candidates$office == "councillor"),
  councillor_wards =
    sort(
      unique(
        candidates$ward[
          candidates$office == "councillor"
        ]
      )
    ),
  map_features =
    length(map_data$features),
  census_sheets =
    census_sheets,
  note = paste(
    "Incumbent matches are exact-name",
    "matches only and require manual review."
  )
)

jsonlite::write_json(
  validation,
  "validation.json",
  pretty = TRUE,
  auto_unbox = TRUE
)

# Run basic checks
stopifnot(
  validation$mayor_candidates == 53L,
  validation$councillor_candidates == 190L,
  identical(
    validation$councillor_wards,
    1:25
  ),
  validation$map_features == 25L
)

# Print summary
message("")
message("Preparation complete.")
message("")
message(
  "Mayor candidates: ",
  validation$mayor_candidates
)
message(
  "Councillor candidates: ",
  validation$councillor_candidates
)
message(
  "Councillor wards: ",
  length(validation$councillor_wards)
)
message(
  "Map features: ",
  validation$map_features
)
