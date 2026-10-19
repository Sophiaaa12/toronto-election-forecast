# run_tests.R
#
# Runs the automated test suite for the Toronto 2026 election forecast.
#
# Usage (from the project root):
#
#   Rscript tests/run_tests.R
#
# Requires the testthat package:
#   install.packages("testthat")

library(testthat)

# Run from the project root regardless of where Rscript was invoked
project_root <- normalizePath(
  if (file.exists("toronto-election-forecast.Rproj")) {
    "."
  } else {
    ".."
  }
)

setwd(project_root)

results <- test_dir(
  file.path(project_root, "tests", "testthat"),
  stop_on_failure = TRUE
)

print(results)
