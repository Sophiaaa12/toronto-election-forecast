# website/make_figures.R
#
# Task 7A: generates every figure and markdown table used by the Quarto
# website from COMMITTED project data only. No LLM APIs are called; no
# production or forecast artifact is modified (this script only READS
# processed/ and data/01-raw_data/ files, and WRITES new files under website/figures
# and website/tables).
#
# Run from anywhere inside the project:
#   Rscript website/make_figures.R
#
# Inputs (all committed):
#   processed/forecast/forecast_summary_centered.parquet   provider forecasts
#   processed/forecast/pooled_point_estimates_descriptive.parquet
#   processed/forecast/sensitivity_target_sd.parquet       target-SD grid
#   processed/production/llm_responses.parquet             response diagnostics
#   processed/diagnostic/c{0,1,2}_ballot_responses.parquet order experiment
#   processed/simulated/candidate_crosswalk.parquet        candidate names
#   data/01-raw_data/geography/wards.geojson, data/01-raw_data/geography/ward_names.xlsx
#
# Outputs:
#   website/figures/fig1..fig6 .png
#   website/tables/race_table.md, mayor_table.md

suppressMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(scales)
  library(patchwork)
  library(ggrepel)
  library(nanoparquet)
  library(sf)
  library(readxl)
})

# --- run from the project root (no setwd) -----------------------------------
if (!file.exists("toronto-election-forecast.Rproj")) {
  stop("Run from the project root: Rscript website/make_figures.R")
}
dir.create("website/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("website/tables", recursive = TRUE, showWarnings = FALSE)

# --- consistent labels / theme ----------------------------------------------
source(file.path("website", "theme_site.R")) # THEME_WEB, palette, save_fig()
PROV_LABEL <- c(
  "google/gemini-2.5-flash-lite" = "Gemini 2.5 Flash Lite",
  "openai/gpt-4o-mini"           = "GPT-4o-mini"
)
SRC_NOTE <- paste(
  "Source: synthetic responses from two LLMs (queried 18 October 2026),",
  "post-stratified to the 2021 Census. Intervals and win frequencies are",
  "simulation summaries, not probabilities of winning the real election."
)
short <- function(x, n = 24) {
  ifelse(nchar(x) <= n, x, paste0(substr(x, 1, n - 4), "..."))
}

# --- load committed data + validations --------------------------------------
summary_c <- read_parquet("processed/forecast/forecast_summary_centered.parquet")
pooled <- read_parquet("processed/forecast/pooled_point_estimates_descriptive.parquet")
sens <- read_parquet("processed/forecast/sensitivity_target_sd.parquet")
cw <- read_parquet("processed/simulated/candidate_crosswalk.parquet")
prod <- read_parquet("processed/production/llm_responses.parquet")

stopifnot(
  nrow(cw) == 243, n_distinct(cw$race_id) == 26,
  nrow(summary_c) == 486,
  setequal(unique(summary_c$race_id), cw$race_id),
  setequal(unique(summary_c$model_id), names(PROV_LABEL)),
  !anyNA(cw$ballot_name),
  setequal(unique(sens$target_sd), c(0.02, 0.04, 0.06))
)
pw <- summary_c |>
  group_by(race_id, model_id) |>
  summarise(s = sum(p_win), .groups = "drop")
stopifnot(max(abs(pw$s - 1)) < 1e-9)

nm <- cw |> select(race_id, candidate_id, ballot_name, ward, incumbent_name_match)
summary_c <- summary_c |> left_join(nm, by = c("race_id", "candidate_id"))
pooled2 <- pooled |> left_join(nm, by = c("race_id", "candidate_id"))
stopifnot(!anyNA(summary_c$ballot_name), !anyNA(pooled2$ballot_name))

ward_names <- read_excel("data/01-raw_data/geography/ward_names.xlsx") |>
  transmute(ward = as.integer(`Ward Number`), ward_name = `Ward Name`)
wlab <- function(w) {
  wn <- ward_names$ward_name[match(w, ward_names$ward)]
  sprintf("W%02d %s", as.integer(w), ifelse(is.na(wn), "", wn))
}

with_prov <- function(df) {
  df |> mutate(provider = factor(PROV_LABEL[model_id], levels = names(PROV_COL)))
}

# --- FIGURE 1: mayoral forecasts by provider ---------------------------------
mayor_cands <- pooled2 |>
  filter(race_id == "mayor") |>
  slice_max(pooled_equal_weight_share, n = 8, with_ties = FALSE) |>
  arrange(pooled_equal_weight_share) |>
  pull(candidate_id)
f1dat <- summary_c |>
  filter(
    race_id == "mayor",
    candidate_id %in% mayor_cands
  ) |>
  with_prov() |>
  mutate(lab = factor(candidate_id,
    levels = mayor_cands,
    labels = short(nm$ballot_name[match(
      paste("mayor", mayor_cands),
      paste(nm$race_id, nm$candidate_id)
    )], 28)
  ))
fig1 <- ggplot(f1dat, aes(y = lab, x = point_share, color = provider)) +
  geom_linerange(aes(xmin = q025, xmax = q975),
    position = position_dodge(width = 0.6),
    linewidth = 1.2, alpha = 0.6
  ) +
  geom_point(position = position_dodge(width = 0.6), size = 2.6) +
  scale_color_manual(values = PROV_COL) +
  scale_x_continuous(
    labels = percent_format(accuracy = 1),
    limits = c(0, 1)
  ) +
  labs(
    title = "Mayoral race: post-stratified vote shares by LLM provider",
    subtitle = paste(strwrap(
      paste(
        "Points: census post-stratified point estimates. Bars: 95% simulation",
        "intervals (assumed forecast noise SD 4 pp). Chow, Olivia dominates both",
        "providers (mode collapse measured in the silicon sample)."
      ),
      width = 110
    ), collapse = "\n"),
    x = "Share of decided first preferences", y = NULL,
    color = "LLM provider",
    caption = paste(strwrap(SRC_NOTE, width = 150), collapse = "\n")
  ) +
  THEME_WEB

save_fig("website/figures/fig1_mayoral.png", fig1, width = 9, height = 5.2)

# --- FIGURE 2: ward races, all 25 wards --------------------------------------
# Candidates shown per ward: anyone in EITHER provider's top two by point
# share, so each provider's own leader always appears (2-4 rows per ward).
ward_show <- summary_c |>
  filter(race_id != "mayor") |>
  group_by(race_id, model_id) |>
  slice_max(point_share, n = 2, with_ties = FALSE) |>
  ungroup() |>
  distinct(race_id, candidate_id) |>
  left_join(pooled2 |> select(race_id, candidate_id, pooled_equal_weight_share),
    by = c("race_id", "candidate_id")
  )
f2dat <- summary_c |>
  filter(race_id != "mayor") |>
  inner_join(ward_show, by = c("race_id", "candidate_id")) |>
  with_prov() |>
  mutate(
    facet = factor(wlab(ward), levels = wlab(1:25)),
    cand = paste0(
      short(ballot_name, 20),
      ifelse(incumbent_name_match, " *", "")
    ),
    key = paste(race_id, candidate_id)
  )
lev2 <- f2dat |>
  distinct(key, cand, pooled_equal_weight_share) |>
  arrange(pooled_equal_weight_share)
f2dat <- f2dat |> mutate(key = factor(key, levels = lev2$key))
fig2 <- ggplot(f2dat, aes(y = key, x = point_share, color = provider)) +
  geom_linerange(aes(xmin = q025, xmax = q975),
    position = position_dodge(width = 0.6),
    linewidth = 1.1, alpha = 0.55
  ) +
  geom_point(position = position_dodge(width = 0.6), size = 1.9) +
  facet_wrap(~facet,
    ncol = 3, scales = "free_y",
    labeller = label_wrap_gen(width = 40)
  ) +
  scale_y_discrete(labels = setNames(lev2$cand, lev2$key)) +
  scale_color_manual(values = PROV_COL) +
  scale_x_continuous(
    labels = percent_format(accuracy = 1),
    limits = c(0, 1), breaks = c(0, 0.5, 1)
  ) +
  labs(
    title = "Ward councillor races: who leads in each ward, by LLM provider",
    subtitle = paste(strwrap(paste(
      "Each panel is one ward. Rows are candidates (each provider's top two;",
      "* = incumbent), ordered by pooled share with the strongest at the top.",
      "Point = provider's post-stratified share; bar = 95% simulation interval.",
      "Where the blue and orange points sit on different rows, the providers",
      "disagree on the leader."
    ), width = 120), collapse = "\n"),
    x = "Share of decided first preferences", y = NULL,
    color = "LLM provider",
    caption = paste(strwrap(SRC_NOTE, width = 150), collapse = "\n")
  ) +
  THEME_WEB +
  theme(
    axis.text.y = element_text(size = 9),
    panel.border = element_rect(fill = NA, color = RULE),
    panel.spacing = unit(0.6, "lines")
  )

save_fig("website/figures/fig2_wards.png", fig2, width = 12, height = 19)

# --- FIGURES 3-4: provider disagreement (dotplot + map) ----------------------
# Leader definition (used consistently across the website): the candidate with
# the provider's highest POST-STRATIFIED POINT SHARE. A win-frequency-based
# definition gives a slightly different set (documented below and in index.qmd).
leaders <- summary_c |>
  group_by(race_id, model_id) |>
  slice_max(point_share, n = 1, with_ties = FALSE) |>
  ungroup()
split_tbl <- leaders |>
  distinct(race_id, model_id, candidate_id) |>
  group_by(race_id) |>
  summarise(split = n_distinct(candidate_id) > 1, .groups = "drop")
f3dat <- leaders |>
  filter(race_id != "mayor") |>
  left_join(split_tbl, by = "race_id") |>
  with_prov() |>
  mutate(facet = factor(wlab(ward), levels = rev(wlab(1:25))))
# Display order: the 8 disagreement wards first (top), then agreeing wards,
# each group in ward order. Set explicitly via scale_y_discrete below so the
# layout does not depend on data row order.
split_wards <- split_tbl |>
  filter(split, grepl("^ward_", race_id)) |>
  mutate(ward = as.integer(sub("ward_(\\d+)_councillor", "\\1", race_id))) |>
  arrange(ward) |>
  pull(ward)
y_order <- rev(c(wlab(split_wards), wlab(setdiff(1:25, split_wards))))

# --- FIGURE 3: provider disagreement dotplot (all 25 wards) ------------------
# Agreeing wards: one shared leader, labelled once (grey) left of the row.
# Split wards: each provider's own leader, labelled in the provider colour.
agree_lab <- f3dat |>
  filter(!split) |>
  group_by(facet) |>
  summarise(x = min(p_win), ballot_name = first(ballot_name), .groups = "drop")
split_lab <- f3dat |>
  filter(split) |>
  group_by(facet) |>
  mutate(left = p_win == min(p_win) & !duplicated(p_win == min(p_win))) |>
  ungroup()
fig3 <- ggplot(f3dat, aes(y = facet)) +
  geom_line(aes(x = p_win, group = race_id),
    color = NEUTRAL, linewidth = 0.8,
    data = f3dat |> filter(!split)
  ) +
  geom_line(aes(x = p_win, group = race_id),
    color = ACCENT, linewidth = 1.1,
    data = f3dat |> filter(split)
  ) +
  geom_point(aes(x = p_win, color = provider, shape = split),
    size = 2.8,
    alpha = 0.9
  ) +
  geom_text(
    data = agree_lab, aes(x = x - 0.02, label = ballot_name),
    hjust = 1, size = 2.9, color = MUTED, family = SITE_FONT
  ) +
  geom_text(
    data = split_lab |> filter(left),
    aes(x = p_win - 0.02, label = ballot_name, color = provider),
    hjust = 1, size = 2.9, family = SITE_FONT, show.legend = FALSE
  ) +
  geom_text(
    data = split_lab |> filter(!left),
    aes(x = p_win + 0.02, label = ballot_name, color = provider),
    hjust = 0, size = 2.9, family = SITE_FONT, show.legend = FALSE
  ) +
  geom_hline(
    yintercept = 25 - length(split_wards) + 0.5,
    color = MUTED, linetype = "dashed", linewidth = 0.4
  ) +
  scale_y_discrete(limits = y_order) +
  scale_color_manual(values = PROV_COL) +
  scale_shape_manual(
    values = c(`TRUE` = 17, `FALSE` = 16),
    labels = c(
      `TRUE` = "Different leaders",
      `FALSE` = "Same leader"
    )
  ) +
  scale_x_continuous(
    labels = percent_format(accuracy = 1),
    limits = c(-0.12, 1.12), breaks = seq(0, 1, 0.25)
  ) +
  labs(
    title = "Provider disagreement across the 25 ward races",
    subtitle = paste(strwrap(
      paste(
        "Each row is a ward; the two points are each provider's simulation win",
        "frequency for its own leading candidate (highest post-stratified point",
        "share). Top block (crimson lines): the providers name different leaders,",
        "both named in provider colour. Bottom block: same leader, named in grey;",
        "a single visible point means both providers are at ~100%."
      ),
      width = 110
    ), collapse = "\n"),
    x = "Simulation win frequency of each provider's leading candidate",
    y = NULL, color = "LLM provider", shape = NULL
  ) +
  THEME_WEB

save_fig("website/figures/fig3_disagreement_dotplot.png", fig3, width = 11, height = 9)

# --- FIGURE 4: Toronto ward disagreement map ---------------------------------
wards_sf <- st_transform(st_read("data/01-raw_data/geography/wards.geojson", quiet = TRUE), 4326)
wards_sf$ward <- as.integer(wards_sf$WARD_NUMBER)
split_names <- leaders |>
  filter(race_id != "mayor") |>
  left_join(split_tbl, by = "race_id") |>
  filter(split) |>
  mutate(who = ifelse(model_id == "openai/gpt-4o-mini", "GPT", "Gemini")) |>
  select(ward, who, ballot_name) |>
  pivot_wider(names_from = who, values_from = ballot_name)
mapdat <- wards_sf |>
  left_join(
    split_tbl |> filter(grepl("^ward_", race_id)) |>
      mutate(ward = as.integer(
        sub("ward_(\\d+)_councillor", "\\1", race_id)
      )) |>
      select(ward, split),
    by = "ward"
  ) |>
  left_join(ward_names, by = "ward") |>
  left_join(split_names, by = "ward")
sf_use_s2(FALSE)
ctr <- suppressWarnings(st_point_on_surface(st_geometry(mapdat)))
mapdat$cx <- st_coordinates(ctr)[, 1]
mapdat$cy <- st_coordinates(ctr)[, 2]
mapdat$num <- sprintf("%d", mapdat$ward)
mapdat$labcol <- ifelse(mapdat$split, ACCENT, INK)
bb <- st_bbox(mapdat)
mapdat$lab <- ifelse(mapdat$split,
  sprintf(
    "W%02d %s\nGemini: %s\nGPT: %s", mapdat$ward, mapdat$ward_name,
    mapdat$Gemini, mapdat$GPT
  ),
  sprintf("W%02d %s", mapdat$ward, mapdat$ward_name)
)
fig4 <- ggplot(mapdat) +
  geom_sf(aes(fill = split), color = PAPER, linewidth = 0.35) +
  geom_text(aes(x = cx, y = cy, label = num),
    size = 3, fontface = "bold",
    color = ifelse(mapdat$split, PAPER, INK), family = SITE_FONT
  ) +
  geom_label_repel(
    aes(x = cx, y = cy, label = lab, color = labcol),
    size = 2.3, fill = alpha(PAPER, 0.92), label.size = 0.15, family = SITE_FONT,
    lineheight = 0.9, segment.size = 0.3, box.padding = 0.3,
    point.padding = 0.5, force = 6, force_pull = 0.2,
    min.segment.length = 0, max.overlaps = Inf, seed = 245309,
    show.legend = FALSE
  ) +
  scale_color_identity() +
  scale_fill_manual(
    values = c(`TRUE` = ACCENT, `FALSE` = NEUTRAL),
    labels = c(
      `TRUE` = "Providers name different leaders",
      `FALSE` = "Providers agree"
    )
  ) +
  coord_sf(
    datum = NA, clip = "off",
    xlim = c(bb[["xmin"]] - 0.02, bb[["xmax"]] + 0.02),
    ylim = c(bb[["ymin"]] - 0.01, bb[["ymax"]] + 0.01)
  ) +
  labs(
    fill = NULL, x = NULL, y = NULL,
    title = "Where the two LLM providers name different ward leaders",
    subtitle = paste(
      "Red wards: providers disagree (each provider's",
      "leader shown). Leader = highest post-stratified point share."
    )
  ) +
  theme_void(base_size = 11, base_family = SITE_FONT) +
  theme(
    plot.title = element_text(face = "bold", color = INK),
    plot.subtitle = element_text(color = MUTED),
    plot.background = element_rect(fill = PAPER, color = NA),
    legend.position = "bottom"
  )

save_fig("website/figures/fig4_disagreement_map.png", fig4, width = 11, height = 7)

# --- FIGURE 5: sensitivity to the perturbation target SD ---------------------
# Leader is fixed per race x provider by point share (identical across SDs),
# then tracked across all three SD values.
slead <- sens |>
  group_by(race_id, model_id, target_sd) |>
  slice_max(point_share, n = 1, with_ties = FALSE) |>
  ungroup() |>
  with_prov() |>
  mutate(
    width_pp = 100 * (q975 - q025),
    sd_lab = factor(sprintf("%.0f pp", 100 * target_sd))
  )
stopifnot(nrow(slead) == 3 * 52)
med5 <- slead |>
  group_by(sd_lab) |>
  summarise(med = median(width_pp), .groups = "drop")
fig5a <- ggplot(slead, aes(x = sd_lab, y = width_pp)) +
  geom_line(aes(group = interaction(race_id, model_id), color = provider),
    alpha = 0.25, linewidth = 0.45
  ) +
  geom_point(aes(color = provider), size = 1.4, alpha = 0.55) +
  geom_line(
    data = med5, aes(y = med, group = 1), color = INK,
    linewidth = 1.2
  ) +
  geom_label(
    data = med5, aes(y = med, label = sprintf("median %.1f", med)),
    nudge_x = 0.3, size = 3, label.size = 0, fill = PAPER,
    family = SITE_FONT
  ) +
  scale_color_manual(values = PROV_COL) +
  labs(
    title = "a) Wider assumed uncertainty widens every leader interval",
    subtitle = "Each line and point is one race x provider leader (52); dark line = median",
    x = "Assumed perturbation target SD (published forecast: 4 pp)",
    y = "Leader 95% interval width (pp)",
    color = "LLM provider"
  ) +
  THEME_WEB
cnt <- slead |>
  group_by(sd_lab) |>
  summarise(n_unity = sum(p_win == 1), .groups = "drop") |>
  mutate(used = sd_lab == "4 pp")
fig5b <- ggplot(cnt, aes(x = sd_lab, y = n_unity, fill = used)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = n_unity),
    vjust = -0.5, fontface = "bold",
    family = SITE_FONT, color = INK
  ) +
  scale_fill_manual(
    values = c(`TRUE` = INK, `FALSE` = NEUTRAL),
    guide = "none"
  ) +
  scale_y_continuous(limits = c(0, 52), breaks = c(0, 13, 26, 39, 52)) +
  labs(
    title = "b) ...and fewer units sit at a 100% win frequency",
    subtitle = "Race x provider units (of 52); dark bar = published setting",
    x = "Assumed perturbation target SD",
    y = "Units with win frequency = 100%"
  ) +
  THEME_WEB
fig5 <- (fig5a | fig5b) + plot_layout(widths = c(1.6, 1)) +
  plot_annotation(
    caption = paste(strwrap(SRC_NOTE, width = 160), collapse = "\n"),
    theme = theme(
      plot.caption = element_text(
        color = MUTED, hjust = 0, size = 8, family = SITE_FONT
      ),
      plot.background = element_rect(fill = PAPER, color = NA)
    )
  )
save_fig("website/figures/fig5_sensitivity.png", fig5, width = 12, height = 5)

# --- FIGURE 6: silicon sampling diagnostics ----------------------------------
diag <- bind_rows(lapply(
  c("c0_ballot_responses", "c1_random_a_responses", "c2_random_b_responses"),
  function(cc) {
    read_parquet(sprintf("processed/diagnostic/%s.parquet", cc)) |>
      mutate(condition = sub("_.*$", "", cc))
  }
))
wide <- diag |>
  filter(response_status == "valid_choice") |>
  select(persona_id, race_id, model_id, repeat_id, condition, candidate_id) |>
  distinct() |>
  pivot_wider(
    names_from = condition, values_from = candidate_id,
    names_prefix = "o_"
  )
inv <- wide |>
  filter(!is.na(o_c0), !is.na(o_c1), !is.na(o_c2)) |>
  mutate(
    invariant = o_c0 == o_c1 & o_c1 == o_c2,
    race_type = ifelse(race_id == "mayor", "Mayoral race",
      "Ward races (12 sampled)"
    )
  ) |>
  mutate(provider = factor(PROV_LABEL[model_id], levels = names(PROV_COL)))
inv_agg <- inv |>
  group_by(race_type, provider) |>
  summarise(rate = mean(invariant), n = n(), .groups = "drop")
fig6a <- ggplot(inv_agg, aes(x = race_type, y = rate, fill = provider)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.55) +
  geom_text(aes(label = percent(rate, accuracy = 0.1)),
    position = position_dodge(width = 0.7), vjust = -0.4, size = 3,
    family = SITE_FONT, color = INK
  ) +
  scale_fill_manual(values = PROV_COL) +
  scale_y_continuous(
    labels = percent_format(accuracy = 1),
    limits = c(0, 1.12)
  ) +
  labs(
    title = "a) Candidate-order invariance",
    subtitle = "Share of persona-race draws choosing the same candidate\nunder all three ballot orders (diagnostic experiment)",
    x = NULL, y = "Order-invariant rate", fill = "LLM provider",
    caption = "Source: ballot-order experiment, each persona-race asked under three candidate orders."
  ) +
  THEME_WEB

may <- prod |> filter(race_id == "mayor", response_status == "valid_choice")
may_n <- may |> count(candidate_id, name = "n")
may_top <- may_n |>
  slice_max(n, n = 8) |>
  pull(candidate_id)
may_lab <- cw |>
  filter(race_id == "mayor", candidate_id %in% may_top) |>
  left_join(may_n, by = "candidate_id") |>
  arrange(desc(n))
fig6bdat <- may |>
  filter(candidate_id %in% may_top) |>
  count(model_id, candidate_id, name = "n") |>
  group_by(model_id) |>
  mutate(share = n / sum(n)) |>
  ungroup() |>
  left_join(may_lab |> select(candidate_id, ballot_name), by = "candidate_id") |>
  with_prov() |>
  mutate(lab = factor(short(ballot_name, 18),
    levels = short(may_lab$ballot_name, 18)
  ))
fig6b <- ggplot(fig6bdat, aes(x = lab, y = share, fill = provider)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.65) +
  scale_fill_manual(values = PROV_COL) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "b) Mayoral response concentration",
    subtitle = "Share of valid mayoral choices (production sample)",
    x = NULL, y = "Share of valid responses", fill = "LLM provider",
    caption = "Source: production silicon sample, 36,504 synthetic responses."
  ) +
  THEME_WEB +
  theme(axis.text.x = element_text(angle = 25, hjust = 1, size = 8))

und <- prod |>
  mutate(race_type = ifelse(race_id == "mayor", "Mayoral race", "Ward races")) |>
  group_by(model_id, race_type) |>
  summarise(rate = mean(response_status == "undecided"), .groups = "drop") |>
  with_prov()
fig6c <- ggplot(und, aes(x = race_type, y = rate, fill = provider)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.55) +
  geom_text(aes(label = percent(rate, accuracy = 0.1)),
    position = position_dodge(width = 0.7), vjust = -0.4, size = 3,
    family = SITE_FONT, color = INK
  ) +
  scale_fill_manual(values = PROV_COL) +
  scale_y_continuous(
    labels = percent_format(accuracy = 1),
    limits = c(0, max(und$rate) * 1.25)
  ) +
  labs(
    title = "c) Provider undecided rates",
    subtitle = "Undecided share of all production responses",
    x = NULL, y = "Undecided rate", fill = "LLM provider",
    caption = "Source: production silicon sample, 36,504 synthetic responses."
  ) +
  THEME_WEB

fig6 <- ((fig6a | fig6b) / fig6c) + plot_layout(heights = c(1, 0.85))
save_fig("website/figures/fig6_diagnostics.png", fig6, width = 12.5, height = 9)

# --- TABLES ------------------------------------------------------------------
race_label <- function(rid) {
  ifelse(rid == "mayor", "Mayor",
    sprintf(
      "Ward %02d councillor",
      as.integer(sub("ward_(\\d+)_councillor", "\\1", rid))
    )
  )
}
lead_s <- leaders |>
  mutate(
    pct = sprintf("%.1f%%", 100 * point_share),
    ci = sprintf("[%.0f-%.0f%%]", 100 * q025, 100 * q975),
    wf = sprintf("%.1f%%", 100 * p_win)
  ) |>
  select(race_id, model_id, candidate_id, ballot_name, pct, ci, wf)
pooled_lead <- pooled2 |>
  group_by(race_id) |>
  slice_max(pooled_equal_weight_share, n = 1, with_ties = FALSE) |>
  ungroup() |>
  mutate(pct = sprintf("%.1f%%", 100 * pooled_equal_weight_share)) |>
  select(race_id, pooled_name = ballot_name, pooled_pct = pct, ward)
K_tbl <- cw |> count(race_id, name = "K")
gem <- lead_s |>
  filter(model_id == "google/gemini-2.5-flash-lite") |>
  transmute(race_id, gem = sprintf("%s<br><span class=\"nw\">%s %s · win %s</span>", ballot_name, pct, ci, wf))
gpt <- lead_s |>
  filter(model_id == "openai/gpt-4o-mini") |>
  transmute(race_id, gpt = sprintf("%s<br><span class=\"nw\">%s %s · win %s</span>", ballot_name, pct, ci, wf))
spl <- split_tbl |> transmute(race_id, split = ifelse(split,
  "**no**", "yes"
))
race_tbl <- pooled_lead |>
  left_join(K_tbl, by = "race_id") |>
  left_join(gem, by = "race_id") |>
  left_join(gpt, by = "race_id") |>
  left_join(spl, by = "race_id") |>
  arrange(ifelse(race_id == "mayor", 0L, as.integer(
    sub("ward_(\\d+)_councillor", "\\1", race_id)
  ))) |>
  transmute(
    Race = ifelse(race_id == "mayor", "Mayor", sprintf("Ward %02d", ward)),
    Candidates = K,
    `Pooled leader` = sprintf("%s<br>%s", pooled_name, pooled_pct),
    `Gemini leader` = gem,
    `GPT leader` = gpt,
    `Same leader?` = split
  )
md_table <- function(df) {
  hdr <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep <- paste0("|", paste(rep(":---", ncol(df)), collapse = "|"), "|")
  rows <- apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
  c(hdr, sep, rows)
}
writeLines(c(
  "<!-- Generated by website/make_figures.R from committed forecast data. -->",
  "",
  md_table(race_tbl),
  "",
  paste(
    ": Leading candidate in all 26 races. Pooled leader is a descriptive",
    "equal-weight average of both providers. Each provider cell gives its",
    "leader's post-stratified share, 95% simulation interval, and simulation",
    "win frequency. Candidates is the number of names on the",
    "ballot. {#tbl-races}"
  )
), "website/tables/race_table.md")

# One row per candidate, providers side by side, sorted by pooled share.
mayor_long <- summary_c |>
  filter(race_id == "mayor") |>
  left_join(
    pooled2 |> filter(race_id == "mayor") |>
      select(candidate_id, pooled_equal_weight_share),
    by = "candidate_id"
  )
mayor_keep <- mayor_long |>
  filter(pooled_equal_weight_share > 0.001 | point_share > 0.005) |>
  distinct(candidate_id)
mayor_tbl <- mayor_long |>
  semi_join(mayor_keep, by = "candidate_id") |>
  mutate(
    who = ifelse(model_id == "openai/gpt-4o-mini", "gpt", "gem"),
    cell = sprintf(
      "%.1f%% [%.1f-%.1f%%]", 100 * point_share,
      100 * q025, 100 * q975
    ),
    wf = sprintf("%.1f%%", 100 * p_win)
  ) |>
  select(
    candidate_id, ballot_name, incumbent_name_match,
    pooled_equal_weight_share, who, cell, wf
  ) |>
  pivot_wider(names_from = who, values_from = c(cell, wf)) |>
  arrange(desc(pooled_equal_weight_share)) |>
  transmute(
    Candidate = ballot_name,
    Incumbent = ifelse(incumbent_name_match, "yes", ""),
    `Pooled share` = sprintf("%.1f%%", 100 * pooled_equal_weight_share),
    `Gemini share [95% interval]` = cell_gem,
    `Gemini win freq.` = wf_gem,
    `GPT share [95% interval]` = cell_gpt,
    `GPT win freq.` = wf_gpt
  )
writeLines(c(
  "<!-- Generated by website/make_figures.R from committed forecast data. -->",
  "",
  md_table(mayor_tbl),
  "",
  paste(
    ": Mayoral candidates with a pooled share above 0.1% or any provider",
    "share above 0.5%, sorted by pooled share. Brackets give 95% simulation",
    "intervals; win frequencies are the share of 500 simulation draws in",
    "which the candidate leads. {#tbl-mayor}"
  )
), "website/tables/mayor_table.md")

# --- printed facts for the website text --------------------------------------
cat("\n=== FACTS FOR WEBSITE TEXT ===\n")
cat("order-invariance:\n")
print(as.data.frame(inv_agg))
cat("\nprovider undecided rates:\n")
print(as.data.frame(und |> mutate(rate = round(100 * rate, 2))))
cat(
  "\nsplit wards (point-share leaders): ",
  paste(sort(sub("ward_(\\d+)_councillor", "W\\1", split_tbl$race_id[split_tbl$split])),
    collapse = ", "
  ), "\n"
)
# Alternative definition, for the reconciliation note in index.qmd:
pw_leaders <- summary_c |>
  group_by(race_id, model_id) |>
  slice_max(p_win, n = 1, with_ties = FALSE) |>
  ungroup() |>
  distinct(race_id, model_id, candidate_id)
pw_split <- pw_leaders |>
  group_by(race_id) |>
  summarise(split = n_distinct(candidate_id) > 1, .groups = "drop")
cat(
  "split wards (win-frequency leaders): ",
  paste(sort(sub("ward_(\\d+)_councillor", "W\\1", pw_split$race_id[pw_split$split])),
    collapse = ", "
  ), "\n"
)
cat("mayoral MAYOR-009 valid share by provider:\n")
print(as.data.frame(may |> group_by(model_id) |>
  summarise(share = mean(candidate_id == "MAYOR-009"), .groups = "drop")))
cat("\nfigures written: fig1..fig6; tables: race_table.md, mayor_table.md\n")
cat("mayor table rows:", nrow(mayor_tbl), "| race table rows:", nrow(race_tbl), "\n")
