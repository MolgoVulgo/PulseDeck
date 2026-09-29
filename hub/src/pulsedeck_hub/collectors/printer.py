"""Multi-printer collector and adapter registry."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from ..config import PrinterConfig
from ..printers.elegoo_cc2 import ElegooCC2Adapter, PrinterError

if TYPE_CHECKING:
    from ..mqtt.client import HubMQTTClient


LOG = logging.getLogger(__name__)


class PrinterCollector:
    """Own one independent protocol adapter per enabled printer."""

    def __init__(self, config: PrinterConfig, mqtt_client: "HubMQTTClient") -> None:
        self.config = config
        self.mqtt = mqtt_client
        self._adapters: list[ElegooCC2Adapter] = []

    def start(self) -> None:
        for device in self.config.devices:
            if not device.enabled:
                continue
            if device.driver != "elegoo_cc2":
                LOG.error("Printer %s uses unsupported driver %s", device.id, device.driver)
                continue
            adapter = ElegooCC2Adapter(device, self.config, self.mqtt)
            try:
                adapter.start()
            except PrinterError as exc:
                LOG.error("Printer %s could not start: %s", device.id, exc)
                continue
            self._adapters.append(adapter)
        LOG.info("Printer collector started with %d adapter(s)", len(self._adapters))

    def stop(self) -> None:
        for adapter in reversed(self._adapters):
            adapter.stop()
        self._adapters.clear()
