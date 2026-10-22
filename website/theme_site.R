# website/theme_site.R
#
# The website's single design grammar for figures: one typeface, one palette,
# one ggplot theme. Sourced by website/make_figures.R and website/make_daily.R
# so every figure (local or rendered by GitHub Actions) looks the same.
#
# Typeface: IBM Plex Sans (SIL Open Font License, website/fonts/LICENSE.txt),
# registered from the bundled .ttf files and drawn with the ragg device, so no
# system font installation is needed. The site CSS (website/custom.scss) uses
# the same family.
#
# Palette (validated for colour-vision deficiency and contrast against the page
# background): one hue per LLM provider, one accent reserved for "the two
# providers disagree", and a neutral ink/grey ramp for everything else.

library(ggplot2)
library(systemfonts)

FONT_DIR <- file.path("website", "fonts")
SITE_FONT <- "IBM Plex Sans"
if (!SITE_FONT %in% systemfonts::registry_fonts()$family) {
  systemfonts::register_font(
    name       = SITE_FONT,
    plain      = file.path(FONT_DIR, "IBMPlexSans-Regular.ttf"),
    bold       = file.path(FONT_DIR, "IBMPlexSans-SemiBold.ttf"),
    italic     = file.path(FONT_DIR, "IBMPlexSans-Italic.ttf"),
    bolditalic = file.path(FONT_DIR, "IBMPlexSans-SemiBold.ttf")
  )
}

# Colours shared with website/custom.scss.
INK      <- "#1c2430" # text, emphasis marks
MUTED    <- "#5f6873" # secondary text, axis labels
RULE     <- "#e3e5e8" # gridlines
NEUTRAL  <- "#c9ced5" # de-emphasised fills (e.g. wards where providers agree)
PAPER    <- "#fbfaf7" # figure and page background
ACCENT   <- "#a32638" # reserved: provider disagreement
PROV_COL <- c("Gemini 2.5 Flash Lite" = "#1f6fa8", "GPT-4o-mini" = "#c77d1e")

THEME_WEB <- theme_minimal(base_size = 11, base_family = SITE_FONT) +
  theme(
    text               = element_text(color = INK),
    axis.text          = element_text(color = MUTED),
    panel.grid.major   = element_line(color = RULE, linewidth = 0.4),
    panel.grid.minor   = element_blank(),
    plot.background    = element_rect(fill = PAPER, color = NA),
    legend.position    = "bottom",
    legend.title       = element_text(color = MUTED, size = 9.5),
    plot.title         = element_text(face = "bold", size = 13),
    plot.title.position = "plot",
    plot.subtitle      = element_text(color = MUTED, size = 10),
    plot.caption       = element_text(color = MUTED, hjust = 0, size = 8),
    plot.caption.position = "plot",
    strip.text         = element_text(face = "bold", size = 9, hjust = 0)
  )

# All figures are written through here: ragg device (bundled font), page
# background, 200 dpi.
save_fig <- function(path, plot, width, height, dpi = 200) {
  ggsave(path, plot, width = width, height = height, dpi = dpi,
         bg = PAPER, device = ragg::agg_png)
}
