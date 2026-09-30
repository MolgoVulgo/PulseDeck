"""Pi-side mini-server monitoring scaffold.

This module intentionally does not define the Agent -> Pi wire transport or
payload.  It only binds the configured target into the hub lifecycle so the
first monitored machine can be represented without pretending collection is
already live.
"""

from __future__ import annotations

import logging

from ..config import MiniServerConfig


LOG = logging.getLogger(__name__)


class MiniServerCollector:
    """Transport-neutral lifecycle shell for the first PulseDeck Agent target."""

    def __init__(self, config: MiniServerConfig) -> None:
        self.config = config
        self.running = False

    @property
    def transport_ready(self) -> bool:
        """Whether a concrete Agent -> Pi transport is implemented."""
        return False

    def start(self) -> None:
        self.running = True
        LOG.warning(
            "Mini-server target %s is configured, but Agent -> Pi transport is not defined; "
            "live metric collection is not started",
            self.config.host,
        )

    def stop(self) -> None:
        self.running = False

    def status(self) -> dict[str, object]:
        return {
            "enabled": self.config.enabled,
            "host": self.config.host,
            "profile": "mini-server",
            "transport": "unresolved",
            "collecting": False,
        }
