# 03_inspect_elections.R
# Inspect historical Toronto election and turnout datasets before cleaning.

library(readxl)

zip_path <- "data/01-raw_data/elections/election_results_2022.zip"
turnout_path <- "data/01-raw_data/elections/turnout_2022.xlsx"
mayor_2023_path <- "data/01-raw_data/elections/mayor_by_election_2023.xlsx"
ward20_path <- "data/01-raw_data/elections/ward20_by_election_2023.xlsx"
ward15_path <- "data/01-raw_data/elections/ward15_by_election_2024.xlsx"
ward25_path <- "data/01-raw_data/elections/ward25_by_election_2025.xlsx"

# Extract the 2022 mayor and councillor files to a temporary directory
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

# Inspect worksheet names in the 2022 election files
excel_sheets(mayor_2022_path)
excel_sheets(councillor_2022_path)

# Inspect the actual 2022 turnout data
turnout_preview <- read_excel(
  turnout_path,
  sheet = "2022 Voter Turnout Statistics",
  col_names = FALSE
)

print(
  turnout_preview[1:30, ]
)

# Inspect a 2022 mayor worksheet
mayor_2022_preview <- read_excel(
  mayor_2022_path,
  sheet = 1,
  col_names = FALSE
)

print(
  mayor_2022_preview[1:30, ]
)

# Inspect a 2022 councillor worksheet
councillor_2022_preview <- read_excel(
  councillor_2022_path,
  sheet = 1,
  col_names = FALSE
)

print(
  councillor_2022_preview[1:30, ]
)

# Inspect the 2023 mayoral by-election data for one ward
mayor_2023_preview <- read_excel(
  mayor_2023_path,
  sheet = "Ward 1",
  col_names = FALSE
)

print(
  mayor_2023_preview[1:30, ]
)

# Inspect the 2023 Ward 20 councillor by-election data
ward20_preview <- read_excel(
  ward20_path,
  sheet = "Ward 20",
  col_names = FALSE
)

print(
  ward20_preview[1:30, ]
)

# Inspect the 2024 Ward 15 councillor by-election data
ward15_preview <- read_excel(
  ward15_path,
  sheet = "Ward 15",
  col_names = FALSE
)

print(
  ward15_preview[1:30, ]
)

# Inspect the 2025 Ward 25 councillor by-election data
ward25_preview <- read_excel(
  ward25_path,
  sheet = "Ward 25",
  col_names = FALSE
)

print(
  ward25_preview[1:30, ]
)

# Inspect the end of each election worksheet
print(
  tail(
    read_excel(
      mayor_2022_path,
      sheet = "Ward 1",
      col_names = FALSE
    ),
    15
  )
)

print(
  tail(
    read_excel(
      councillor_2022_path,
      sheet = "Ward 1",
      col_names = FALSE
    ),
    15
  )
)

print(
  tail(
    read_excel(
      mayor_2023_path,
      sheet = "Ward 1",
      col_names = FALSE
    ),
    15
  )
)

print(
  tail(
    read_excel(
      ward20_path,
      sheet = "Ward 20",
      col_names = FALSE
    ),
    15
  )
)

print(
  tail(
    read_excel(
      ward15_path,
      sheet = "Ward 15",
      col_names = FALSE
    ),
    15
  )
)

print(
  tail(
    read_excel(
      ward25_path,
      sheet = "Ward 25",
      col_names = FALSE
    ),
    15
  )
)

# Inspect exact turnout column names
turnout <- read_excel(
  turnout_path,
  sheet = "2022 Voter Turnout Statistics"
)

names(turnout)
