"""PulseDeck hub entry point and in-process runtime controller."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
import signal
import threading

from .admin.app import AdminServer
from .collectors.weather import WeatherCollector
from .config import DEFAULT_CONFIG_PATH, HubConfig, load_config
from .health.state import HealthState
from .logging_setup import configure_logging
from .mqtt.client import HubMQTTClient


LOG = logging.getLogger(__name__)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pulsedeck-hub")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        help=f"TOML configuration path (default: {DEFAULT_CONFIG_PATH})",
    )
    return parser


class HubRuntime:
    def __init__(self, config_path: Path, config: HubConfig) -> None:
        self.config_path = config_path
        self.config = config
        self.health = HealthState()
        self.health.configure_weather(config.weather.enabled)
        self.mqtt_client = HubMQTTClient(config.mqtt)
        self.weather_collector: WeatherCollector | None = None
        self.admin_server: AdminServer | None = None
        self._config_lock = threading.RLock()

    def _start_weather(self) -> None:
        self.health.configure_weather(self.config.weather.enabled)
        if self.config.weather.enabled:
            self.weather_collector = WeatherCollector(self.config.weather, self.mqtt_client, self.health)
            self.weather_collector.start()
        else:
            self.weather_collector = None

    def start(self) -> None:
        self.mqtt_client.start()
        self._start_weather()
        if self.config.admin.enabled:
            self.admin_server = AdminServer(self)
            self.admin_server.start()

    def reload_weather(self) -> None:
        """Reload only mutable collector configuration without restarting the hub."""
        with self._config_lock:
            new_config = load_config(self.config_path)
            if new_config.mqtt != self.config.mqtt:
                raise ValueError("MQTT changes require a service restart")
            if new_config.admin != self.config.admin:
                raise ValueError("Admin listener changes require a service restart")
            old = self.weather_collector
            if old is not None:
                old.stop()
            self.config = new_config
            self._start_weather()

    def stop(self) -> None:
        if self.admin_server is not None:
            self.admin_server.stop()
        if self.weather_collector is not None:
            self.weather_collector.stop()
        self.mqtt_client.stop()


def main() -> int:
    args = _parser().parse_args()
    configure_logging()
    try:
        config = load_config(args.config)
    except (OSError, ValueError) as exc:
        LOG.error("Configuration error: %s", exc)
        return 2

    stop_event = threading.Event()

    def request_stop(signum, frame) -> None:  # noqa: ANN001
        LOG.info("Shutdown requested by signal %s", signum)
        stop_event.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    runtime = HubRuntime(args.config, config)
    runtime.start()
    try:
        stop_event.wait()
    finally:
        runtime.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
