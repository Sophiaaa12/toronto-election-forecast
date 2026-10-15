# 04_clean_historical_results.R
# Clean historical Toronto mayoral and councillor election results.

library(readxl)
library(dplyr)
library(purrr)
library(stringr)
library(readr)

zip_path <- "raw/elections/election_results_2022.zip"
mayor_2023_path <- "raw/elections/mayor_by_election_2023.xlsx"
ward20_path <- "raw/elections/ward20_by_election_2023.xlsx"
ward15_path <- "raw/elections/ward15_by_election_2024.xlsx"
ward25_path <- "raw/elections/ward25_by_election_2025.xlsx"

# Extract the 2022 mayor and councillor workbooks
temp_2022 <- tempdir()

unzip(
  zip_path,
  files = c(
    "2022_Toronto_Poll_By_Poll_Mayor.xlsx",
    "2022_Toronto_Poll_By_Poll_Councillor.xlsx"
  ),
  exdir = temp_2022
)

mayor_2022_path <- file.path(
  temp_2022,
  "2022_Toronto_Poll_By_Poll_Mayor.xlsx"
)

councillor_2022_path <- file.path(
  temp_2022,
  "2022_Toronto_Poll_By_Poll_Councillor.xlsx"
)

# Clean one election worksheet
clean_election_sheet <- function(
    path,
    sheet,
    year,
    office,
    election_type
) {
  data <- read_excel(
    path,
    sheet = sheet,
    col_names = FALSE
  )
  
  first_column <- trimws(
    as.character(data[[1]])
  )
  
  total_row <- which(
    str_detect(
      first_column,
      regex("^City Ward", ignore_case = TRUE)
    )
  )
  
  if (length(total_row) == 0) {
    stop(
      paste(
        "Could not find ward total row in",
        sheet
      )
    )
  }
  
  total_row <- max(total_row)
  
  candidate_data <- data[
    4:(total_row - 1),
    ,
    drop = FALSE
  ]
  
  candidate <- trimws(
    as.character(candidate_data[[1]])
  )
  
  vote_columns <- candidate_data[
    ,
    -1,
    drop = FALSE
  ]
  
  vote_columns <- vote_columns |>
    mutate(
      across(
        everything(),
        ~ suppressWarnings(as.numeric(.x))
      )
    )
  
  votes <- rowSums(
    vote_columns,
    na.rm = TRUE
  )
  
  ward <- as.integer(
    str_remove(sheet, "Ward ")
  )
  
  result <- tibble(
    year = year,
    election_type = election_type,
    office = office,
    ward = ward,
    candidate = candidate,
    votes = votes
  ) |>
    filter(
      !is.na(candidate),
      candidate != ""
    ) |>
    mutate(
      total_valid_votes = sum(votes),
      vote_share = votes / total_valid_votes
    )
  
  result
}

# Clean all 25 wards from the 2022 mayoral election
mayor_2022 <- map_dfr(
  excel_sheets(mayor_2022_path),
  ~ clean_election_sheet(
    path = mayor_2022_path,
    sheet = .x,
    year = 2022,
    office = "mayor",
    election_type = "general"
  )
)

# Clean all 25 wards from the 2022 councillor elections
councillor_2022 <- map_dfr(
  excel_sheets(councillor_2022_path),
  ~ clean_election_sheet(
    path = councillor_2022_path,
    sheet = .x,
    year = 2022,
    office = "councillor",
    election_type = "general"
  )
)

# Clean all 25 wards from the 2023 mayoral by-election
mayor_2023 <- map_dfr(
  excel_sheets(mayor_2023_path)[-1],
  ~ clean_election_sheet(
    path = mayor_2023_path,
    sheet = .x,
    year = 2023,
    office = "mayor",
    election_type = "by-election"
  )
)

# Clean the 2023 Ward 20 councillor by-election
ward20_2023 <- clean_election_sheet(
  path = ward20_path,
  sheet = "Ward 20",
  year = 2023,
  office = "councillor",
  election_type = "by-election"
)

# Clean the 2024 Ward 15 councillor by-election
ward15_2024 <- clean_election_sheet(
  path = ward15_path,
  sheet = "Ward 15",
  year = 2024,
  office = "councillor",
  election_type = "by-election"
)

# Clean the 2025 Ward 25 councillor by-election
ward25_2025 <- clean_election_sheet(
  path = ward25_path,
  sheet = "Ward 25",
  year = 2025,
  office = "councillor",
  election_type = "by-election"
)

# Combine all historical election results
historical_results <- bind_rows(
  mayor_2022,
  councillor_2022,
  mayor_2023,
  ward20_2023,
  ward15_2024,
  ward25_2025
) |>
  arrange(
    office,
    year,
    ward,
    desc(vote_share)
  )

# Check ward coverage
stopifnot(
  n_distinct(
    mayor_2022$ward
  ) == 25,
  n_distinct(
    councillor_2022$ward
  ) == 25,
  n_distinct(
    mayor_2023$ward
  ) == 25
)

# Check that vote shares sum to one within each race
vote_share_check <- historical_results |>
  group_by(
    year,
    election_type,
    office,
    ward
  ) |>
  summarise(
    total = sum(vote_share),
    .groups = "drop"
  )

stopifnot(
  all(
    abs(vote_share_check$total - 1) < 1e-8
  )
)

# Save cleaned historical election results
write_csv(
  historical_results,
  "processed/historical_results.csv"
)