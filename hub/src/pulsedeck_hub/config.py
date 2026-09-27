"""Configuration primitives for the PulseDeck hub.

The versioned example configuration lives in config/pulsedeck.example.toml.
Runtime paths and secret storage locations are intentionally not fixed yet.
"""

from __future__ import annotations

from pathlib import Path
import tomllib
from typing import Any


def load_toml(path: Path) -> dict[str, Any]:
    """Load a TOML configuration file without imposing an application schema yet."""
    with path.open("rb") as handle:
        return tomllib.load(handle)
