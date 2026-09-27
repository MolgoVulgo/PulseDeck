"""Runtime configuration for the PulseDeck hub."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import tomllib


DEFAULT_CONFIG_PATH = Path("/etc/pulsedeck/pulsedeck.toml")


@dataclass(frozen=True, slots=True)
class MQTTConfig:
    host: str
    port: int = 1883
    namespace: str = "pulsedeck/v1"
    client_id: str = "pulsedeck-hub"
    keepalive: int = 30
    reconnect_min_delay: int = 1
    reconnect_max_delay: int = 30

    @property
    def availability_topic(self) -> str:
        return f"{self.namespace.rstrip('/')}/system/availability"


@dataclass(frozen=True, slots=True)
class HubConfig:
    mqtt: MQTTConfig


def _positive_int(value: object, name: str, *, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must be <= {maximum}")
    return value


def load_config(path: Path = DEFAULT_CONFIG_PATH) -> HubConfig:
    with path.open("rb") as handle:
        raw = tomllib.load(handle)

    mqtt_raw = raw.get("mqtt")
    if not isinstance(mqtt_raw, dict):
        raise ValueError("missing [mqtt] configuration section")

    host = mqtt_raw.get("host")
    if not isinstance(host, str) or not host.strip():
        raise ValueError("mqtt.host must be a non-empty string")

    namespace = mqtt_raw.get("namespace", "pulsedeck/v1")
    client_id = mqtt_raw.get("client_id", "pulsedeck-hub")
    if not isinstance(namespace, str) or not namespace.strip("/"):
        raise ValueError("mqtt.namespace must be a non-empty string")
    if not isinstance(client_id, str) or not client_id.strip():
        raise ValueError("mqtt.client_id must be a non-empty string")

    cfg = MQTTConfig(
        host=host.strip(),
        port=_positive_int(mqtt_raw.get("port", 1883), "mqtt.port", maximum=65535),
        namespace=namespace.strip("/"),
        client_id=client_id.strip(),
        keepalive=_positive_int(mqtt_raw.get("keepalive", 30), "mqtt.keepalive"),
        reconnect_min_delay=_positive_int(mqtt_raw.get("reconnect_min_delay", 1), "mqtt.reconnect_min_delay"),
        reconnect_max_delay=_positive_int(mqtt_raw.get("reconnect_max_delay", 30), "mqtt.reconnect_max_delay"),
    )
    if cfg.reconnect_min_delay > cfg.reconnect_max_delay:
        raise ValueError("mqtt.reconnect_min_delay must be <= mqtt.reconnect_max_delay")
    return HubConfig(mqtt=cfg)
