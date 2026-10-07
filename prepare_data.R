# Run from the project root: source("prepare_data.R")
# Required packages: jsonlite, readxl
prepare_data <- function(root = ".") {
  for (pkg in c("jsonlite", "readxl")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("Install the required package: ", pkg, call. = FALSE)
    }
  }
  raw_path <- function(name) file.path(root, "raw", "core", name)
  read_json <- function(path) jsonlite::fromJSON(path, simplifyVector = FALSE)
  output <- file.path(root, "processed")
  dir.create(output, recursive = TRUE, showWarnings = FALSE)

  officials <- read_json(raw_path("2022-2026-elected-officials-contact-info.json"))
  incumbents <- list()
  for (person in officials) {
    role <- person[["Primary role"]]
    if (!role %in% c("Mayor", "Councillor")) next
    office <- if (role == "Mayor") "mayor" else "councillor"
    ward <- if (role == "Mayor") 0L else as.integer(person[["District ID"]])
    incumbents[[paste(office, ward, sep = ":")]] <- tolower(
      paste(person[["First name"]], person[["Last name"]])
    )
  }

  rows <- list()
  filenames <- c(mayor = "mayorCandidates_2026.json",
                 councillor = "councilorCandidates_2026.json")
  for (office in names(filenames)) {
    data <- read_json(raw_path(filenames[[office]]))
    groups <- if (office == "mayor") {
      list(list(num = 0L, candidate = data$candidates))
    } else data$ward
    for (group in groups) {
      ward <- as.integer(group$num)
      for (candidate in group$candidate) {
        display_name <- paste(candidate$firstName, candidate$lastName)
        incumbent <- incumbents[[paste(office, ward, sep = ":")]]
        websites <- vapply(Filter(function(x) identical(x$name, "web"),
                                  candidate$socialMedias),
                           function(x) x$url, character(1))
        rows[[length(rows) + 1L]] <- data.frame(
          office = office, ward = ward, ballot_name = candidate$name,
          display_name = display_name, status = candidate$status,
          incumbent_name_match = !is.null(incumbent) &&
            identical(tolower(display_name), incumbent),
          website = paste(websites, collapse = " | "),
          source = "https://www.toronto.ca/city-government/elections/candidate-list/",
          stringsAsFactors = FALSE
        )
      }
    }
  }
  candidates <- do.call(rbind, rows)
  utils::write.csv(candidates, file.path(output, "candidates_2026.csv"),
                   row.names = FALSE, na = "", fileEncoding = "UTF-8")

  # Retain worksheet rows, including original headings and explanatory text.
  # Read cells as text to avoid losing labels in mixed-type columns.
  export_sheet <- function(path, sheet, filename) {
    values <- readxl::read_excel(path, sheet = sheet, col_names = FALSE,
                                col_types = "text", .name_repair = "minimal")
    utils::write.table(values, file.path(output, filename), sep = ",",
                       row.names = FALSE, col.names = FALSE, na = "",
                       qmethod = "double", fileEncoding = "UTF-8")
  }
  export_sheet(raw_path("25-wardnames-numbers.xlsx"), 1, "wards.csv")
  census <- raw_path("2023-wardprofiles-2011-2021-censusdata_rev0719.xlsx")
  for (sheet in c("2021 One Variable", "2021 Two Variable")) {
    filename <- paste0("census_", tolower(gsub(" ", "_", sheet)), ".csv")
    export_sheet(census, sheet, filename)
  }

  sources <- read_json(file.path(root, "sources.json"))
  failures <- Filter(function(x) !is.null(x$error), sources)
  map <- read_json(raw_path("ward-and-elected-councillor-4326.geojson"))
  checks <- list(
    mayor_candidates = sum(candidates$office == "mayor"),
    councillor_candidates = sum(candidates$office == "councillor"),
    wards = sort(unique(candidates$ward[candidates$office == "councillor"])),
    map_features = length(map$features), download_failures = failures,
    incumbency_note = paste("Exact name matches only; manually review spelling",
                            "and incumbency before modeling.")
  )
  jsonlite::write_json(checks, file.path(root, "validation.json"),
                       pretty = TRUE, auto_unbox = TRUE)
  # These counts apply to the supplied October 7, 2026 snapshot.
  stopifnot(checks$mayor_candidates == 53L,
            checks$councillor_candidates == 190L,
            identical(checks$wards, 1:25), checks$map_features == 25L,
            length(failures) == 0L)
  print(checks)
  invisible(checks)
}
prepare_data()
