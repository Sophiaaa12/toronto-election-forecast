# Optional refresh only: the supplied raw files are already downloaded.
# Run from the project root: source("download_data.R")
# Required packages: jsonlite, digest
# Refreshing overwrites source files and sources.json with a newer snapshot.
download_data <- function(root = ".") {
  for (pkg in c("jsonlite", "digest")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("Install the required package: ", pkg, call. = FALSE)
    }
  }
  old_timeout <- getOption("timeout")
  options(timeout = max(60, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)
  dir.create(file.path(root, "raw"), recursive = TRUE, showWarnings = FALSE)
  base <- "https://ckan0.cf.opendata.inter.prod-toronto.ca/api/3/action/package_show?id="
  specifications <- list(
    list(id = "ward-profiles-25-ward-model", role = "core",
         select = function(x) TRUE),
    list(id = "wards-and-elected-councillors", role = "core",
         select = function(x) endsWith(x$url, "4326.geojson")),
    list(id = "elected-officials-contact-information", role = "core",
         select = function(x) endsWith(x$url, "2022-2026-elected-officials-contact-info.json")),
    list(id = "election-results-official", role = "historical_optional",
         select = function(x) identical(x$name, "2022-results")),
    list(id = "elections-voter-statistics", role = "historical_optional",
         select = function(x) identical(x$name, "2022-voter-statistics")),
    list(id = "elections-official-by-election-results", role = "historical_optional",
         select = function(x) identical(x$name, "2023 Office of the Mayor") ||
           (grepl("Councillor", x$name, fixed = TRUE) &&
              grepl("2023|2024|2025", x$name)))
  )
  items <- list()
  for (spec in specifications) {
    response <- jsonlite::fromJSON(paste0(base, spec$id), simplifyVector = FALSE)
    if (!isTRUE(response$success)) stop("Metadata request failed: ", spec$id)
    metadata <- response$result
    jsonlite::write_json(metadata,
      file.path(root, "raw", paste0(spec$id, "_metadata.json")),
      pretty = TRUE, auto_unbox = TRUE, null = "null")
    resources <- Filter(spec$select, metadata$resources)
    if (!length(resources)) stop("No matching resources: ", spec$id)
    for (resource in resources) {
      items[[length(items) + 1L]] <- list(
        name = resource$name, url = resource$url,
        source_website = paste0("https://open.toronto.ca/dataset/", spec$id, "/"),
        role = spec$role, license = metadata$license_title
      )
    }
  }
  for (filename in c("mayorCandidates_2026.json", "councilorCandidates_2026.json",
                     "withdrawnCandidates_2026.json")) {
    items[[length(items) + 1L]] <- list(
      name = filename,
      url = paste0("https://www.toronto.ca/data/elections/candidate_list/", filename),
      source_website = "https://www.toronto.ca/city-government/elections/candidate-list/",
      role = "core", license = "City website terms; check before redistribution"
    )
  }
  for (i in seq_along(items)) {
    item <- items[[i]]
    filename <- basename(sub("[?#].*$", "", item$url))
    relative <- paste("raw", item$role, filename, sep = "/")
    destination <- file.path(root, relative)
    dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
    temporary <- tempfile(tmpdir = dirname(destination))
    item <- tryCatch({
      status <- utils::download.file(item$url, temporary, mode = "wb", quiet = TRUE)
      if (status != 0L) stop("Download returned status ", status)
      if (!file.copy(temporary, destination, overwrite = TRUE)) stop("Cannot save download")
      item$file <- relative
      item$bytes <- unname(file.info(destination)$size)
      item$sha256 <- digest::digest(file = destination, algo = "sha256")
      item$downloaded_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
      message(filename, " (", item$bytes, " bytes)")
      item
    }, error = function(e) {
      item$error <- conditionMessage(e)
      message("FAILED: ", item$name, ": ", item$error)
      item
    })
    unlink(temporary)
    items[[i]] <- item
  }
  jsonlite::write_json(items, file.path(root, "sources.json"),
                       pretty = TRUE, auto_unbox = TRUE, null = "null")
  if (any(vapply(items, function(x) !is.null(x$error), logical(1)))) {
    stop("Some downloads failed. Review sources.json before preparing data.")
  }
  invisible(items)
}
download_data()
