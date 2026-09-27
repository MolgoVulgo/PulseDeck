"""PulseDeck hub entry point."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
import signal
import threading

from .config import DEFAULT_CONFIG_PATH, load_config
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

    mqtt_client = HubMQTTClient(config.mqtt)
    mqtt_client.start()
    try:
        stop_event.wait()
    finally:
        mqtt_client.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
