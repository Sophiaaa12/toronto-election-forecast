# 01_inspect_census.R
# Inspect the structure and available variables in the 2021 Toronto ward Census data.

library(readxl)

census_path <- "raw/census/ward_profiles_2021.xlsx"

# List available worksheets
excel_sheets(census_path)

# Read the 2021 Census worksheets
one_variable <- read_excel(
  census_path,
  sheet = "2021 One Variable",
  col_names = FALSE
)

two_variable <- read_excel(
  census_path,
  sheet = "2021 Two Variable",
  col_names = FALSE
)

# Check worksheet dimensions
dim(one_variable)
dim(two_variable)

# Helper for displaying non-missing values in selected rows
show_rows <- function(data, start, end) {
  
  for (i in start:end) {
    
    values <- unlist(
      data[i, ],
      use.names = FALSE
    )
    
    values <- values[!is.na(values)]
    
    cat(
      "Row", i, ":",
      paste(values, collapse = " | "),
      "\n"
    )
  }
}

# Inspect the beginning of the One Variable worksheet
show_rows(
  one_variable,
  1,
  40
)

# Search the One Variable worksheet for relevant demographic variables
first_col <- one_variable[[1]]

keywords <- c(
  "age",
  "gender",
  "sex",
  "education",
  "income",
  "tenure",
  "population"
)

for (word in keywords) {
  
  cat(
    "\n---",
    toupper(word),
    "---\n"
  )
  
  print(
    which(
      grepl(
        word,
        first_col,
        ignore.case = TRUE
      )
    )
  )
}

# Inspect relevant sections of the One Variable worksheet
show_rows(
  one_variable,
  45,
  70
)

show_rows(
  one_variable,
  980,
  1010
)

show_rows(
  one_variable,
  1348,
  1415
)

show_rows(
  one_variable,
  1420,
  1482
)

# Helper for searching all columns of the Two Variable worksheet
search_two_variable <- function(word) {
  
  matches <- which(
    apply(
      two_variable,
      1,
      function(row) {
        any(
          grepl(
            word,
            row,
            ignore.case = TRUE
          ),
          na.rm = TRUE
        )
      }
    )
  )
  
  cat(
    "\n---",
    toupper(word),
    "---\n"
  )
  
  print(matches)
  
  if (length(matches) > 0) {
    show_rows(
      two_variable,
      max(1, min(matches) - 3),
      min(nrow(two_variable), max(matches) + 3)
    )
  }
}

# Check whether useful demographic cross-tabulations are available
search_two_variable("age")
search_two_variable("education")
search_two_variable("degree")
search_two_variable("gender")
search_two_variable("income")
search_two_variable("tenure")