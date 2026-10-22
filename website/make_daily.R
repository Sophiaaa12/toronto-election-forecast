# website/make_daily.R
#
# Figures and markdown tables for the Daily Tracker section of index.qmd,
# built from the committed daily history. No API calls.
#
# Usage (from anywhere inside the project):
#   Rscript website/make_daily.R [daily_dir] [site_dir]
#
# Inputs:
#   processed/daily/history.csv        (R/12_daily_forecast.R)
#   processed/daily/stats_history.csv
#   processed/daily/news/<date>.json
#   data/01-raw_data/geography/ward_names.xlsx
#
# Outputs:
#   website/figures/daily_mayor.png, daily_wards.png
#   website/tables/daily_*.md

suppressMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(scales)
  library(readxl)
})

# Run from the project root (no setwd); the GitHub Action does this.
if (!file.exists("toronto-election-forecast.Rproj")) {
  stop("Run from the project root: Rscript website/make_daily.R")
}
source(file.path("website", "theme_site.R")) # THEME_WEB, palette, fonts

args <- commandArgs(trailingOnly = TRUE)
DAILY_DIR <- if (length(args) >= 1) args[1] else file.path("processed", "daily")
SITE_DIR <- if (length(args) >= 2) args[2] else "website"
FIG_DIR <- file.path(SITE_DIR, "figures")
TAB_DIR <- file.path(SITE_DIR, "tables")
dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(TAB_DIR, recursive = TRUE, showWarnings = FALSE)

MA_DAYS <- 5
PROV_LABEL <- c(
  "google/gemini-2.5-flash-lite" = "Gemini 2.5 Flash Lite",
  "openai/gpt-4o-mini"           = "GPT-4o-mini"
)
# Mayoral candidates keep one colour each across the page; minor candidates
# share muted greys (they stay near 0% and are named in the legend).
cand_cols <- function(names) {
  fixed <- c("Olivia Chow" = "#6a4c9c", "Brad Bradford" = "#2f8a5f")
  greys <- c("#8a929c", "#aab1b9", "#c9ced5", "#d9dde2")
  other <- setdiff(names, names(fixed))
  c(
    fixed[intersect(names(fixed), names)],
    setNames(greys[seq_along(other)], other)
  )
}
pct <- function(x, d = 1) sprintf(paste0("%.", d, "f%%"), 100 * x)
prov <- function(m) ifelse(m %in% names(PROV_LABEL), PROV_LABEL[m], m)
md_table <- function(df) {
  esc <- function(x) gsub("|", "\\|", as.character(x), fixed = TRUE)
  c(
    paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
    apply(df, 1, function(r) paste0("| ", paste(esc(r), collapse = " | "), " |"))
  )
}
write_md <- function(lines, name) {
  writeLines(enc2utf8(lines), file.path(TAB_DIR, name), useBytes = TRUE)
}

history_path <- file.path(DAILY_DIR, "history.csv")
if (!file.exists(history_path)) {
  msg <- "_No daily runs yet. The first results appear after the next scheduled run of the daily GitHub Action._"
  for (f in c(
    "daily_headline.md", "daily_mayor_table.md", "daily_mayor_today.md",
    "daily_ward_table.md", "daily_news.md", "daily_costs.md"
  )) {
    write_md(msg, f)
  }
  placeholder <- ggplot() +
    annotate("text", x = 0, y = 0, label = "No daily runs yet", size = 6, colour = MUTED) +
    theme_void()
  for (f in c("daily_mayor.png", "daily_wards.png")) {
    save_fig(file.path(FIG_DIR, f), placeholder, width = 9, height = 2, dpi = 100)
  }
  message("No daily history yet; wrote placeholder tables.")
  quit(save = "no")
}

history <- readr::read_csv(history_path,
  show_col_types = FALSE,
  col_types = readr::cols(poll_date = "D")
)
stats <- readr::read_csv(file.path(DAILY_DIR, "stats_history.csv"),
  show_col_types = FALSE,
  col_types = readr::cols(poll_date = "D")
)
dates <- sort(unique(history$poll_date))
latest <- max(dates)

ward_names <- read_excel(file.path("raw", "geography", "ward_names.xlsx")) |>
  transmute(ward = as.integer(`Ward Number`), ward_name = `Ward Name`)
ward_of <- function(race_id) as.integer(sub("ward_(\\d+)_councillor", "\\1", race_id))

# Cross-provider daily average, then a trailing moving average over the
# last MA_DAYS polled days (fewer at the start of the series).
daily_avg <- history |>
  group_by(poll_date, race_id, candidate_id, display_name, incumbent) |>
  summarise(avg_share = mean(point_share), n_models = n(), .groups = "drop")
ma <- daily_avg |>
  group_by(race_id, candidate_id) |>
  arrange(poll_date, .by_group = TRUE) |>
  mutate(ma_share = sapply(seq_along(poll_date), function(i) {
    in_win <- poll_date > poll_date[i] - MA_DAYS & poll_date <= poll_date[i]
    mean(avg_share[in_win])
  })) |>
  ungroup()
latest_ma <- ma |> filter(poll_date == latest)

# ---- headline ---------------------------------------------------------------
news_latest <- file.path(DAILY_DIR, "news", paste0(latest, ".json"))
fetched <- if (file.exists(news_latest)) jsonlite::fromJSON(news_latest)$fetched_at_utc else NA
updated <- if (!is.na(fetched)) {
  format(as.POSIXct(fetched, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "%A, %B %d, %Y, %I:%M %p %Z",
    tz = "America/Toronto"
  )
} else {
  format(latest, "%A, %B %d, %Y")
}

mayor_top <- latest_ma |>
  filter(race_id == "mayor") |>
  slice_max(ma_share, n = 5, with_ties = FALSE)
n_window <- sum(dates > latest - MA_DAYS)
write_md(c(
  paste0(
    "**Latest estimate** \u00b7 ", n_window, "-day average across ",
    n_distinct(history$model_id[history$poll_date == latest]),
    " models \u00b7 Updated ", updated, " \u00b7 ", length(dates),
    " polling day", ifelse(length(dates) == 1, "", "s"), " so far"
  ),
  "",
  md_table(data.frame(
    `Mayoral candidate` = mayor_top$display_name,
    `Share of decided voters` = pct(mayor_top$ma_share),
    check.names = FALSE
  ))
), "daily_headline.md")

# ---- mayoral trend figure ---------------------------------------------------
top_ids <- mayor_top$candidate_id
mayor_hist <- history |>
  filter(race_id == "mayor", candidate_id %in% top_ids) |>
  mutate(
    cand = factor(display_name, levels = mayor_top$display_name),
    provider = prov(model_id)
  )
mayor_ma <- ma |>
  filter(race_id == "mayor", candidate_id %in% top_ids) |>
  mutate(cand = factor(display_name, levels = mayor_top$display_name))

p_mayor <- ggplot() +
  geom_line(
    data = mayor_hist,
    aes(poll_date, point_share,
      colour = cand,
      group = interaction(cand, provider), linetype = provider
    ),
    alpha = 0.45, linewidth = 0.5
  ) +
  geom_point(
    data = mayor_hist,
    aes(poll_date, point_share, colour = cand, shape = provider),
    alpha = 0.6, size = 1.6
  ) +
  geom_line(data = mayor_ma, aes(poll_date, ma_share, colour = cand), linewidth = 1.6) +
  geom_point(data = mayor_ma, aes(poll_date, ma_share, colour = cand), size = 2.4) +
  scale_y_continuous(labels = percent_format(accuracy = 1), limits = c(0, NA)) +
  scale_x_date(date_labels = "%b %d", breaks = pretty_breaks(min(length(dates), 8))) +
  geom_vline(xintercept = as.Date("2026-10-26"), linetype = "dotted", colour = MUTED) +
  scale_colour_manual(values = cand_cols(levels(mayor_ma$cand))) +
  labs(
    title = "Toronto mayor: daily silicon-sample estimates",
    subtitle = paste0(
      "Thick lines: ", MA_DAYS, "-day moving average of the cross-model mean. ",
      "Thin lines/points: each model's daily post-stratified share."
    ),
    x = NULL, y = "Share of decided first preferences",
    colour = NULL, linetype = NULL, shape = NULL,
    caption = paste(
      "Source: daily synthetic responses from a fixed 1,200-persona panel per model,",
      "prompted with that day's Toronto news headlines. Not a poll; not a calibrated probability."
    )
  ) +
  THEME_WEB +
  guides(colour = guide_legend(nrow = 2))
save_daily <- function(plot, name, ...) {
  # geom_line() warns on single-day series; expected at the start of the run.
  suppressMessages(save_fig(file.path(FIG_DIR, name), plot, dpi = 150, ...))
}
save_daily(p_mayor, "daily_mayor.png", width = 9, height = 5.5)

# ---- latest mayoral detail ----------------------------------------------------
today <- history |> filter(poll_date == latest)
mayor_today <- today |>
  filter(race_id == "mayor", candidate_id %in% top_ids) |>
  mutate(
    cell = sprintf(
      "%s [%s, %s] \u00b7 win %s", pct(point_share), pct(q025),
      pct(q975), pct(p_win, 0)
    ),
    provider = prov(model_id)
  ) |>
  select(display_name, provider, cell) |>
  pivot_wider(names_from = provider, values_from = cell) |>
  mutate(display_name = factor(display_name, levels = mayor_top$display_name)) |>
  arrange(display_name) |>
  rename(Candidate = display_name)
write_md(c(
  paste0(
    "Results for ", format(latest, "%B %d, %Y"),
    ": post-stratified share [95% simulation interval] \u00b7 simulation win frequency."
  ),
  "", md_table(mayor_today)
), "daily_mayor_today.md")

# ---- per-day mayoral table (last 14 days) -----------------------------------
top2 <- head(mayor_top, 2)
per_day <- history |>
  filter(
    race_id == "mayor", candidate_id %in% top2$candidate_id,
    poll_date > latest - 14
  ) |>
  mutate(col = paste0(display_name, " (", prov(model_id), ")")) |>
  select(poll_date, col, point_share) |>
  mutate(point_share = pct(point_share, 0)) |>
  pivot_wider(names_from = col, values_from = point_share) |>
  arrange(desc(poll_date)) |>
  rename(Date = poll_date)
col_order <- as.vector(outer(
  top2$display_name, paste0(" (", PROV_LABEL, ")"),
  paste0
) |> t())
per_day <- per_day[, c("Date", intersect(col_order, names(per_day)))]
write_md(md_table(per_day), "daily_mayor_table.md")

# ---- ward figure + table ----------------------------------------------------
ward_ma <- ma |>
  filter(race_id != "mayor") |>
  mutate(ward = ward_of(race_id))
ward_top <- ward_ma |>
  filter(poll_date == latest) |>
  group_by(ward) |>
  slice_max(ma_share, n = 2, with_ties = FALSE) |>
  mutate(rank = row_number()) |>
  ungroup()
ward_plot <- ward_ma |>
  inner_join(ward_top |> select(ward, candidate_id, rank), by = c("ward", "candidate_id")) |>
  left_join(ward_names, by = "ward") |>
  mutate(
    panel = sprintf("W%02d %s", ward, ward_name),
    rank = factor(rank, labels = c("1st", "2nd")[seq_along(unique(rank))])
  )
lab_dat <- ward_plot |>
  filter(poll_date == latest) |>
  mutate(lab = paste0(
    sub(" .*$", "", display_name) |> substr(1, 1), ". ",
    sub("^.* ", "", display_name)
  ))
p_wards <- ggplot(ward_plot, aes(poll_date, ma_share, colour = rank, group = candidate_id)) +
  geom_line(linewidth = 1) +
  geom_point(size = 1.2) +
  geom_text(
    data = lab_dat, aes(label = lab), hjust = 1, vjust = -0.6, size = 2.4,
    family = SITE_FONT,
    show.legend = FALSE
  ) +
  facet_wrap(~panel, ncol = 5) +
  scale_colour_manual(values = c("1st" = INK, "2nd" = "#8a929c")) +
  scale_y_continuous(labels = percent_format(accuracy = 1), limits = c(0, 1)) +
  scale_x_date(date_labels = "%m-%d", breaks = pretty_breaks(3)) +
  labs(
    title = "Ward councillor races: top two candidates over time",
    subtitle = paste0(
      MA_DAYS, "-day moving average of the cross-model mean post-stratified share; ",
      "rank as of ", format(latest, "%b %d")
    ),
    x = NULL, y = NULL, colour = "Rank today",
    caption = "Source: daily synthetic responses. About 48 panel personas per ward and model per day, so ward lines are noisy."
  ) +
  THEME_WEB +
  theme(axis.text = element_text(size = 7))
save_daily(p_wards, "daily_wards.png", width = 11, height = 12)

leaders_today <- today |>
  filter(race_id != "mayor") |>
  group_by(race_id, model_id) |>
  slice_max(point_share, n = 1, with_ties = FALSE) |>
  ungroup() |>
  mutate(
    ward = ward_of(race_id), provider = prov(model_id),
    lab = paste0(display_name, " (", pct(point_share, 0), ")")
  ) |>
  select(ward, provider, lab) |>
  pivot_wider(names_from = provider, values_from = lab, names_prefix = "Today: ")
ward_tbl <- ward_top |>
  filter(rank <= 2) |>
  mutate(lab = paste0(display_name, ifelse(incumbent, "*", "")), share = pct(ma_share)) |>
  select(ward, rank, lab, share) |>
  pivot_wider(names_from = rank, values_from = c(lab, share)) |>
  left_join(ward_names, by = "ward") |>
  left_join(leaders_today, by = "ward") |>
  arrange(ward) |>
  mutate(Ward = sprintf("W%02d %s", ward, ward_name)) |>
  select(Ward,
    Leader = lab_1, `Leader share` = share_1,
    `Runner-up` = lab_2, `Runner-up share` = share_2, starts_with("Today: ")
  )
write_md(
  c(
    md_table(ward_tbl), "",
    paste0(
      "Leader and runner-up by ", n_window, "-day average of the cross-model mean; ",
      "\\* = incumbent. \"Today\" columns give each model's own leader on ",
      format(latest, "%B %d"), "."
    )
  ),
  "daily_ward_table.md"
)

# ---- news -------------------------------------------------------------------
if (file.exists(news_latest)) {
  news <- jsonlite::fromJSON(news_latest)
  items <- news$items
  lines <- sprintf(
    "- **%s**: [%s](%s)", items$source, items$title,
    ifelse(is.na(items$link), "#", items$link)
  )
  write_md(c(
    paste0(
      "Headlines shown to every persona on ", format(latest, "%B %d, %Y"),
      " (", nrow(items), " items from ", news$n_sources_ok, " feeds):"
    ),
    "", lines
  ), "daily_news.md")
} else {
  write_md("_No news file for the latest day._", "daily_news.md")
}

# ---- costs --------------------------------------------------------------------
cost_tbl <- stats |>
  arrange(desc(poll_date), model_id) |>
  transmute(
    Date = poll_date, Model = prov(model_id),
    Requests = comma(requests), Valid = comma(valid_choice),
    Undecided = comma(undecided), Failed = comma(failed),
    `Input tokens` = comma(input_tokens), Cached = comma(cached_tokens),
    `Output tokens` = comma(output_tokens), Cost = dollar(cost_usd, accuracy = 0.01)
  )
total <- sum(stats$cost_usd)
write_md(
  c(
    md_table(cost_tbl), "",
    paste0(
      "Cumulative daily-tracker spend: **", dollar(total, accuracy = 0.01),
      "** over ", length(dates), " day", ifelse(length(dates) == 1, "", "s"),
      " (actual cost reported by OpenRouter)."
    )
  ),
  "daily_costs.md"
)

message("Daily tracker figures/tables written for ", length(dates), " day(s); latest ", latest)
