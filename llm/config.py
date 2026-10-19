# llm/config.py
#
# Model configuration and API key handling for the OpenRouter client.
#
# Responsibilities:
#   - load model entries from a JSON config file (llm/models.json,
#     with llm/models.example.json committed as a template);
#   - validate model entries (ID format, provider, generation params,
#     prompt version);
#   - read the API key from the OPENROUTER_API_KEY environment
#     variable ONLY. Keys are never read from or written to source
#     code, config files, or any output artifact.
#
# "Do not hardcode unverified model IDs": the committed example file
# contains clearly-marked placeholder IDs ("example-org/example-model").
# Execution mode (any run that would spend credits) refuses entries
# whose model_id is still a placeholder; dry-run mode permits them so
# the whole pipeline can be exercised without an account.

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Optional

# Environment variable holding the OpenRouter API key. This is the only
# place the key is ever read from.
API_KEY_ENV_VAR = "OPENROUTER_API_KEY"

# OpenRouter model IDs look like "vendor/model-slug" (e.g. the ID shown
# on openrouter.ai/models). We validate the shape but deliberately do
# NOT ship a list of real IDs: availability and pricing change, and the
# assignment forbids hardcoding unverified model IDs.
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")

# Sentinel values that must be replaced before a paid run.
PLACEHOLDER_MODEL_IDS = {"example-org/example-model"}

# Any model whose vendor prefix starts with "example-" is treated as an
# unverified placeholder, regardless of the exact slug.
PLACEHOLDER_VENDOR_PREFIX = "example-"

PROMPT_VERSION_RE = re.compile(r"^v[0-9]+([.][0-9]+)?$")

# OpenRouter endpoint used for chat completions.
OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"


class ConfigError(ValueError):
    """Raised when model configuration is missing or invalid."""


@dataclass(frozen=True)
class ModelConfig:
    """One configured model (one provider arm).

    Attributes are recorded verbatim into every request's metadata and
    into the cache key, so changing any of them invalidates cached
    responses for that model.
    """

    model_id: str                 # OpenRouter model ID ("vendor/model")
    provider: str                 # provider label (usually the "vendor" part)
    model_version: Optional[str]  # explicit version tag, if the analyst pins one
    temperature: float            # sampling temperature (0..2]
    max_tokens: int               # max output tokens for the JSON reply
    prompt_version: str           # version tag of the prompt template
    timeout_seconds: float        # per-request HTTP timeout
    max_retries: int              # retry budget for transient failures

    def __post_init__(self) -> None:
        if not MODEL_ID_RE.match(self.model_id):
            raise ConfigError(
                f"model_id {self.model_id!r} is not a valid OpenRouter ID "
                "(expected 'vendor/model-slug')"
            )
        if not self.provider:
            raise ConfigError(f"model {self.model_id}: provider must be set")
        if not (0.0 < self.temperature <= 2.0):
            raise ConfigError(
                f"model {self.model_id}: temperature must be in (0, 2], "
                f"got {self.temperature}"
            )
        if self.max_tokens < 16:
            raise ConfigError(
                f"model {self.model_id}: max_tokens must be >= 16 "
                "(a strict JSON reply needs room)"
            )
        if not PROMPT_VERSION_RE.match(self.prompt_version):
            raise ConfigError(
                f"model {self.model_id}: prompt_version must look like 'v1' "
                f"or 'v1.2', got {self.prompt_version!r}"
            )
        if self.timeout_seconds <= 0:
            raise ConfigError(f"model {self.model_id}: timeout must be > 0")
        if self.max_retries < 0:
            raise ConfigError(f"model {self.model_id}: max_retries must be >= 0")

    @property
    def is_placeholder(self) -> bool:
        vendor = self.model_id.split("/", 1)[0]
        return (
            self.model_id in PLACEHOLDER_MODEL_IDS
            or vendor.startswith(PLACEHOLDER_VENDOR_PREFIX)
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _default_provider(model_id: str) -> str:
    """Derive a provider label from the model ID's vendor prefix."""
    return model_id.split("/", 1)[0]


def load_model_configs(path: str | Path) -> list[ModelConfig]:
    """Load and validate model entries from a JSON config file.

    Expected format:
        {
          "models": [
            {
              "model_id": "vendor/model",
              "provider": "vendor",            # optional; defaults to prefix
              "model_version": null,           # optional pin
              "temperature": 0.7,
              "max_tokens": 256,
              "prompt_version": "v1",
              "timeout_seconds": 60,
              "max_retries": 5
            }
          ]
        }
    """
    path = Path(path)
    if not path.exists():
        raise ConfigError(
            f"model config not found: {path}\n"
            "Copy llm/models.example.json to llm/models.json and fill in "
            "verified model IDs from https://openrouter.ai/models"
        )
    try:
        raw = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{path}: invalid JSON: {exc}") from exc

    entries = raw.get("models")
    if not isinstance(entries, list) or not entries:
        raise ConfigError(f"{path}: top-level 'models' must be a non-empty list")

    configs: list[ModelConfig] = []
    seen: set[str] = set()
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            raise ConfigError(f"{path}: models[{i}] must be an object")
        model_id = e.get("model_id")
        if not model_id:
            raise ConfigError(f"{path}: models[{i}] is missing 'model_id'")
        if model_id in seen:
            raise ConfigError(f"{path}: duplicate model_id {model_id!r}")
        seen.add(model_id)
        provider = e.get("provider") or _default_provider(model_id)
        configs.append(
            ModelConfig(
                model_id=model_id,
                provider=provider,
                model_version=e.get("model_version"),
                temperature=float(e.get("temperature", 0.7)),
                max_tokens=int(e.get("max_tokens", 256)),
                prompt_version=str(e.get("prompt_version", "v1")),
                timeout_seconds=float(e.get("timeout_seconds", 60.0)),
                max_retries=int(e.get("max_retries", 5)),
            )
        )
    return configs


def require_verified_models(configs: list[ModelConfig]) -> None:
    """Refuse to run against placeholder (unverified) model IDs.

    Called by execution mode only; dry-run mode allows placeholders.
    """
    bad = [c.model_id for c in configs if c.is_placeholder]
    if bad:
        raise ConfigError(
            "refusing to submit paid requests with placeholder model IDs: "
            + ", ".join(bad)
            + "\nReplace them with verified IDs from "
            "https://openrouter.ai/models in llm/models.json"
        )
    if len({c.provider for c in configs}) < 1:
        raise ConfigError("at least one model provider is required")


def require_two_providers(configs: list[ModelConfig]) -> None:
    """The assignment requires >= 2 distinct model providers."""
    providers = {c.provider for c in configs}
    if len(providers) < 2:
        raise ConfigError(
            "the forecast design requires at least two distinct model "
            f"providers; config currently has: {sorted(providers) or 'none'}"
        )


def get_api_key(required: bool = True) -> Optional[str]:
    """Read the OpenRouter API key from the environment.

    Never reads keys from files or source code. Returns None when the
    variable is unset (dry-run mode must work without a key).
    """
    key = os.environ.get(API_KEY_ENV_VAR, "").strip()
    if required and not key:
        raise ConfigError(
            f"environment variable {API_KEY_ENV_VAR} is not set.\n"
            "Export it before a real run, e.g.\n"
            f"  export {API_KEY_ENV_VAR}=sk-or-...\n"
            "Dry runs do not require a key: add --dry-run."
        )
    return key or None
