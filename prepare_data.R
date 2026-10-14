# prepare_data.R
#
# Convert raw Toronto election data into simple processed tables
# and perform basic validation checks.
#
# Run from the project root:
#
#   source("prepare_data.R")
#
# Required packages:
#   install.packages(c("jsonlite", "readxl"))

library(jsonlite)
library(readxl)


# 1. Create processed directory

dir.create(
  "processed",
  recursive = TRUE,
  showWarnings = FALSE
)



# 2. Check that required raw files exist

required_files <- c(
  "raw/census/ward_profiles_2021.xlsx",
  
  "raw/candidates/mayor_candidates_2026.json",
  "raw/candidates/councillor_candidates_2026.json",
  "raw/candidates/withdrawn_candidates_2026.json",
  
  "raw/elections/election_results_2022.zip",
  "raw/elections/turnout_2022.xlsx",
  "raw/elections/mayor_by_election_2023.xlsx",
  "raw/elections/ward20_by_election_2023.xlsx",
  "raw/elections/ward15_by_election_2024.xlsx",
  "raw/elections/ward25_by_election_2025.xlsx",
  
  "raw/geography/wards.geojson",
  "raw/geography/ward_names.xlsx",
  
  "raw/incumbency/elected_officials_2022_2026.json"
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


# 3. Helper functions

read_json_raw <- function(path) {
  jsonlite::fromJSON(
    path,
    simplifyVector = FALSE
  )
}


export_excel_sheet <- function(path, sheet, output_file) {
  
  x <- readxl::read_excel(
    path,
    sheet = sheet,
    col_names = FALSE,
    col_types = "text",
    .name_repair = "minimal"
  )
  
  utils::write.table(
    x,
    output_file,
    sep = ",",
    row.names = FALSE,
    col.names = FALSE,
    na = "",
    qmethod = "double",
    fileEncoding = "UTF-8"
  )
  
  message("Created: ", output_file)
}


# 4. Current incumbents

officials <- read_json_raw(
  "raw/incumbency/elected_officials_2022_2026.json"
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


# 5. 2026 candidate lists

candidate_files <- c(
  mayor =
    "raw/candidates/mayor_candidates_2026.json",
  
  councillor =
    "raw/candidates/councillor_candidates_2026.json"
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
      
      
      # Candidate website, when supplied
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


utils::write.csv(
  candidates,
  "processed/candidates_2026.csv",
  row.names = FALSE,
  na = "",
  fileEncoding = "UTF-8"
)

message(
  "Created: processed/candidates_2026.csv"
)


# 6. Ward lookup

export_excel_sheet(
  path =
    "raw/geography/ward_names.xlsx",
  
  sheet = 1,
  
  output_file =
    "processed/wards_raw.csv"
)


# 7. Census worksheets

census_file <-
  "raw/census/ward_profiles_2021.xlsx"


census_sheets <- excel_sheets(
  census_file
)

required_census_sheets <- c(
  "2021 One Variable",
  "2021 Two Variable"
)

if (!all(
  required_census_sheets %in%
  census_sheets
)) {
  
  stop(
    "Required 2021 Census worksheets were not found."
  )
}


export_excel_sheet(
  path = census_file,
  sheet = "2021 One Variable",
  output_file =
    "processed/census_2021_one_variable_raw.csv"
)


export_excel_sheet(
  path = census_file,
  sheet = "2021 Two Variable",
  output_file =
    "processed/census_2021_two_variable_raw.csv"
)


# 8. Basic validation

map_data <- read_json_raw(
  "raw/geography/wards.geojson"
)


validation <- list(
  
  mayor_candidates =
    sum(
      candidates$office == "mayor"
    ),
  
  councillor_candidates =
    sum(
      candidates$office == "councillor"
    ),
  
  councillor_wards =
    sort(
      unique(
        candidates$ward[
          candidates$office ==
            "councillor"
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


# 9. Snapshot checks

stopifnot(
  validation$mayor_candidates == 53L,
  validation$councillor_candidates == 190L,
  identical(
    validation$councillor_wards,
    1:25
  ),
  validation$map_features == 25L
)


# 10. Summary

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
  length(
    validation$councillor_wards
  )
)

message(
  "Map features: ",
  validation$map_features
)

message("")
message(
  "Important: Census outputs are raw worksheet conversions."
)

message(
  "They are NOT yet cleaned modelling data."
)