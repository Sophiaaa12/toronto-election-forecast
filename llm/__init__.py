# llm package
#
# Real LLM sampling infrastructure for the Toronto 2026 election
# forecast (Assignment II, Task 3).
#
# This package implements OpenRouter API integration: model
# configuration, persona prompt construction, strict JSON response
# validation, disk-based response caching, retry/backoff handling, and
# cost tracking with a configurable budget.
#
# Design constraints (enforced in code and documented in README.md):
#   - No paid API calls are made by tests or by --dry-run mode.
#   - API keys are read ONLY from the OPENROUTER_API_KEY environment
#     variable and are never written to source code or any output.
#   - Output schema (processed/llm_responses.parquet) is compatible
#     with the simulated pipeline in R/simulation_helpers.R, so the
#     existing post-stratification and forecast code is reused as-is.
#
# The model IDs in llm/models.example.json are PLACEHOLDERS. Verified
# model IDs must be supplied by the analyst in llm/models.json (or via
# --config) before any real run; execution mode refuses placeholder
# IDs by design.

__version__ = "0.1.0"
