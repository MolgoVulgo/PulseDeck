"""PulseDeck hub entry point and in-process runtime controller."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
import signal
import threading

from . import __version__
from .admin.app import AdminServer
from .collectors.mini_server import MiniServerCollector
from .collectors.news import NewsCollector
from .collectors.printer import PrinterCollector
from .collectors.weather import WeatherCollector
from .config import DEFAULT_CONFIG_PATH, HubConfig, load_config
from .health.state import HealthState
from .logging_setup import configure_logging
from .mqtt.client import HubMQTTClient
from .update import UpdateChecker


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
        self.health.configure_news(config.news.enabled)
        self.mqtt_client = HubMQTTClient(config.mqtt)
        self.weather_collector: WeatherCollector | None = None
        self.news_collector: NewsCollector | None = None
        self.mini_server_collector: MiniServerCollector | None = None
        self.printer_collector: PrinterCollector | None = None
        self.admin_server: AdminServer | None = None
        self.update_checker = UpdateChecker(__version__)
        self._config_lock = threading.RLock()

    def _start_weather(self) -> None:
        self.health.configure_weather(self.config.weather.enabled)
        if self.config.weather.enabled:
            self.weather_collector = WeatherCollector(self.config.weather, self.mqtt_client, self.health)
            self.weather_collector.start()
        else:
            self.weather_collector = None

    def _start_news(self) -> None:
        self.health.configure_news(self.config.news.enabled)
        if self.config.news.enabled:
            self.news_collector = NewsCollector(self.config.news, self.mqtt_client, self.health)
            self.news_collector.start()
        else:
            self.news_collector = None

    def _start_mini_server(self) -> None:
        if self.config.mini_server.enabled:
            self.mini_server_collector = MiniServerCollector(self.config.mini_server, self.mqtt_client)
            self.mini_server_collector.start()
        else:
            self.mini_server_collector = None

    def _start_printer(self) -> None:
        if self.config.printer.enabled:
            self.printer_collector = PrinterCollector(self.config.printer, self.mqtt_client)
            self.printer_collector.start()
        else:
            self.printer_collector = None

    def start(self) -> None:
        self.mqtt_client.start()
        self._start_weather()
        self._start_news()
        self._start_mini_server()
        self._start_printer()
        if self.config.admin.enabled:
            self.admin_server = AdminServer(self)
            self.admin_server.start()
        self.update_checker.trigger()

    def _reload_collectors(self, *, weather: bool = False, news: bool = False, printer: bool = False) -> None:
        with self._config_lock:
            new_config = load_config(self.config_path)
            if new_config.mqtt != self.config.mqtt:
                raise ValueError("MQTT changes require a service restart")
            if new_config.admin != self.config.admin:
                raise ValueError("Admin listener changes require a service restart")
            if new_config.mini_server != self.config.mini_server:
                raise ValueError("Mini-server changes require a service restart")
            if not printer and new_config.printer != self.config.printer:
                raise ValueError("Printer changes require reload_printer")
            if not weather and new_config.weather != self.config.weather:
                raise ValueError("Weather changes require reload_weather")
            if not news and new_config.news != self.config.news:
                raise ValueError("News changes require reload_news")

            if weather and self.weather_collector is not None:
                self.weather_collector.stop()
            if news and self.news_collector is not None:
                self.news_collector.stop()
            if printer and self.printer_collector is not None:
                self.printer_collector.stop()

            self.config = new_config
            if weather:
                self._start_weather()
            if news:
                self._start_news()
            if printer:
                self._start_printer()

    def reload_weather(self) -> None:
        """Reload Weather configuration without restarting the hub."""
        self._reload_collectors(weather=True)

    def reload_news(self) -> None:
        """Reload News configuration without restarting the hub."""
        self._reload_collectors(news=True)

    def reload_printer(self) -> None:
        """Reload Printer configuration without restarting the hub."""
        self._reload_collectors(printer=True)

    def stop(self) -> None:
        if self.admin_server is not None:
            self.admin_server.stop()
        if self.printer_collector is not None:
            self.printer_collector.stop()
        if self.mini_server_collector is not None:
            self.mini_server_collector.stop()
        if self.news_collector is not None:
            self.news_collector.stop()
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
