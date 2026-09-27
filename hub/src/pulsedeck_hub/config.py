"""Runtime configuration for the PulseDeck hub."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import tomllib


DEFAULT_CONFIG_PATH = Path("/etc/pulsedeck/pulsedeck.toml")
DEFAULT_OPENWEATHER_KEY_PATH = Path("/etc/pulsedeck/secrets/openweather_api_key")


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
class AdminConfig:
    enabled: bool = False
    listen: str = "127.0.0.1"
    port: int = 8080


@dataclass(frozen=True, slots=True)
class WeatherConfig:
    enabled: bool = False
    provider: str = "openweather-onecall-4"
    latitude: float | None = None
    longitude: float | None = None
    location_name: str = ""
    api_key_file: Path = DEFAULT_OPENWEATHER_KEY_PATH
    lang: str = "fr"
    current_interval: int = 600
    hourly_interval: int = 1800
    daily_interval: int = 10800
    hourly_hours: int = 48
    daily_days: int = 10
    request_timeout: int = 15


@dataclass(frozen=True, slots=True)
class HubConfig:
    mqtt: MQTTConfig
    admin: AdminConfig
    weather: WeatherConfig


def _positive_int(value: object, name: str, *, minimum: int = 1, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must be <= {maximum}")
    return value


def _bool(value: object, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
    return value


def _coordinate(value: object, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a number")
    result = float(value)
    if not minimum <= result <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return result


def weather_config_from_mapping(raw: object) -> WeatherConfig:
    if raw is None:
        return WeatherConfig()
    if not isinstance(raw, dict):
        raise ValueError("[collectors.weather] must be a table")

    enabled = _bool(raw.get("enabled", False), "collectors.weather.enabled")
    provider = raw.get("provider", "openweather-onecall-4")
    if not isinstance(provider, str) or provider != "openweather-onecall-4":
        raise ValueError("collectors.weather.provider must be 'openweather-onecall-4'")

    latitude_raw = raw.get("latitude")
    longitude_raw = raw.get("longitude")
    latitude = None if latitude_raw is None else _coordinate(latitude_raw, "collectors.weather.latitude", -90, 90)
    longitude = None if longitude_raw is None else _coordinate(longitude_raw, "collectors.weather.longitude", -180, 180)
    if enabled and (latitude is None or longitude is None):
        raise ValueError("enabled weather collector requires latitude and longitude")

    location_name = raw.get("location_name", "")
    lang = raw.get("lang", "fr")
    api_key_file = raw.get("api_key_file", str(DEFAULT_OPENWEATHER_KEY_PATH))
    for value, name in ((location_name, "location_name"), (lang, "lang"), (api_key_file, "api_key_file")):
        if not isinstance(value, str):
            raise ValueError(f"collectors.weather.{name} must be a string")
    if not lang.strip():
        raise ValueError("collectors.weather.lang must not be empty")
    if not api_key_file.strip():
        raise ValueError("collectors.weather.api_key_file must not be empty")

    return WeatherConfig(
        enabled=enabled,
        provider=provider,
        latitude=latitude,
        longitude=longitude,
        location_name=location_name.strip(),
        api_key_file=Path(api_key_file),
        lang=lang.strip(),
        current_interval=_positive_int(raw.get("current_interval", 600), "collectors.weather.current_interval", minimum=600),
        hourly_interval=_positive_int(raw.get("hourly_interval", 1800), "collectors.weather.hourly_interval", minimum=600),
        daily_interval=_positive_int(raw.get("daily_interval", 10800), "collectors.weather.daily_interval", minimum=600),
        hourly_hours=_positive_int(raw.get("hourly_hours", 48), "collectors.weather.hourly_hours", maximum=48),
        daily_days=_positive_int(raw.get("daily_days", 10), "collectors.weather.daily_days", maximum=10),
        request_timeout=_positive_int(raw.get("request_timeout", 15), "collectors.weather.request_timeout", maximum=60),
    )


def _admin_config(raw: object) -> AdminConfig:
    if raw is None:
        return AdminConfig()
    if not isinstance(raw, dict):
        raise ValueError("[admin] must be a table")
    enabled = _bool(raw.get("enabled", False), "admin.enabled")
    listen = raw.get("listen", "127.0.0.1")
    if not isinstance(listen, str) or not listen.strip():
        raise ValueError("admin.listen must be a non-empty string")
    return AdminConfig(
        enabled=enabled,
        listen=listen.strip(),
        port=_positive_int(raw.get("port", 8080), "admin.port", maximum=65535),
    )


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

    mqtt = MQTTConfig(
        host=host.strip(),
        port=_positive_int(mqtt_raw.get("port", 1883), "mqtt.port", maximum=65535),
        namespace=namespace.strip("/"),
        client_id=client_id.strip(),
        keepalive=_positive_int(mqtt_raw.get("keepalive", 30), "mqtt.keepalive"),
        reconnect_min_delay=_positive_int(mqtt_raw.get("reconnect_min_delay", 1), "mqtt.reconnect_min_delay"),
        reconnect_max_delay=_positive_int(mqtt_raw.get("reconnect_max_delay", 30), "mqtt.reconnect_max_delay"),
    )
    if mqtt.reconnect_min_delay > mqtt.reconnect_max_delay:
        raise ValueError("mqtt.reconnect_min_delay must be <= mqtt.reconnect_max_delay")

    collectors_raw = raw.get("collectors", {})
    if not isinstance(collectors_raw, dict):
        raise ValueError("[collectors] must be a table")

    return HubConfig(
        mqtt=mqtt,
        admin=_admin_config(raw.get("admin")),
        weather=weather_config_from_mapping(collectors_raw.get("weather")),
    )
