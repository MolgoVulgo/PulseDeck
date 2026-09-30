"""Runtime configuration for the PulseDeck hub."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import tomllib


DEFAULT_CONFIG_PATH = Path("/etc/pulsedeck/pulsedeck.toml")
DEFAULT_OPENWEATHER_KEY_PATH = Path("/etc/pulsedeck/secrets/openweather_api_key")
DEFAULT_NEWSAPI_KEY_PATH = Path("/etc/pulsedeck/secrets/newsapi_api_key")
DEFAULT_GNEWS_KEY_PATH = Path("/etc/pulsedeck/secrets/gnews_api_key")
DEFAULT_PRINTER_SECRET_DIR = Path("/etc/pulsedeck/secrets/printers")
NEWS_PROVIDERS = {"newsapi", "gnews"}
NEWSAPI_CATEGORIES = {
    "general",
    "business",
    "technology",
    "entertainment",
    "sports",
    "science",
    "health",
}
NEWSAPI_MODES = {"top-headlines", "everything"}
GNEWS_MODES = {"top-headlines", "search"}
GNEWS_CATEGORIES = {"general", "world", "nation", "business", "technology", "entertainment", "sports", "science", "health"}
NEWSAPI_LANGUAGES = {"ar", "de", "en", "es", "fr", "he", "it", "nl", "no", "pt", "ru", "sv", "ud", "zh"}
NEWSAPI_COUNTRIES = {
    "ae", "ar", "at", "au", "be", "bg", "br", "ca", "ch", "cn", "co", "cu", "cz", "de", "eg",
    "fr", "gb", "gr", "hk", "hu", "id", "ie", "il", "in", "it", "jp", "kr", "lt", "lv", "ma",
    "mx", "my", "ng", "nl", "no", "nz", "ph", "pl", "pt", "ro", "rs", "ru", "sa", "se", "sg",
    "si", "sk", "th", "tr", "tw", "ua", "us", "ve", "za",
}
NEWS_SEARCH_FIELDS = {"title", "description", "content"}
NEWSAPI_SORT_ORDERS = {"relevancy", "popularity", "publishedAt"}
GNEWS_SORT_ORDERS = {"publishedAt", "relevance"}
GNEWS_NULLABLE_FIELDS = {"description", "content", "image"}


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
class NewsConfig:
    enabled: bool = False
    provider: str = "newsapi"
    mode: str = "top-headlines"
    query: str = ""
    sources: str = ""
    country: str = "fr"
    category: str = ""
    search_in: str = ""
    domains: str = ""
    exclude_domains: str = ""
    from_date: str = ""
    to_date: str = ""
    lang: str = "fr"
    sort_by: str = "publishedAt"
    nullable: str = ""
    max_articles: int = 10
    interval: int = 1800
    request_timeout: int = 15
    api_key_file: Path = DEFAULT_NEWSAPI_KEY_PATH


@dataclass(frozen=True, slots=True)
class MiniServerConfig:
    enabled: bool = False
    host: str = ""
    port: int = 8765
    poll_interval: int = 2
    request_timeout: int = 2
    offline_after_failures: int = 3
    max_snapshot_age: int = 10


@dataclass(frozen=True, slots=True)
class PrinterDeviceConfig:
    id: str
    driver: str
    host: str
    access_code_file: Path
    enabled: bool = True
    port: int = 1883
    reconnect_min_delay: int = 2
    reconnect_max_delay: int = 30


@dataclass(frozen=True, slots=True)
class PrinterConfig:
    enabled: bool = False
    devices: tuple[PrinterDeviceConfig, ...] = ()
    poll_interval: int = 5
    request_timeout: int = 8
    thumbnail_max_base64_bytes: int = 2_000_000
    thumbnail_max_png_bytes: int = 1_500_000
    thumbnail_max_pixels: int = 1_000_000


@dataclass(frozen=True, slots=True)
class HubConfig:
    mqtt: MQTTConfig
    admin: AdminConfig
    weather: WeatherConfig
    news: NewsConfig
    printer: PrinterConfig
    mini_server: MiniServerConfig = MiniServerConfig()


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


def _optional_choice(value: object, name: str, choices: set[str]) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    result = value.strip().lower()
    if result and result not in choices:
        raise ValueError(f"{name} is unsupported")
    return result


def _optional_two_letter_code(value: object, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    result = value.strip().lower()
    if result and (len(result) != 2 or not result.isalpha()):
        raise ValueError(f"{name} must be empty or a 2-letter code")
    return result


def _csv(value: object, name: str, *, maximum_items: int | None = None) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    items = [item.strip() for item in value.split(",") if item.strip()]
    if maximum_items is not None and len(items) > maximum_items:
        raise ValueError(f"{name} must contain at most {maximum_items} comma-separated values")
    if len(set(items)) != len(items):
        raise ValueError(f"{name} contains duplicate values")
    return ",".join(items)


def _search_in(value: object) -> str:
    result = _csv(value, "collectors.news.search_in")
    if result:
        fields = result.split(",")
        if any(field not in NEWS_SEARCH_FIELDS for field in fields):
            raise ValueError("collectors.news.search_in contains an unsupported field")
    return result


def _optional_iso8601(value: object, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    result = value.strip()
    if not result:
        return ""
    from datetime import datetime
    try:
        datetime.fromisoformat(result.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"{name} must be ISO 8601") from exc
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


def news_config_from_mapping(raw: object) -> NewsConfig:
    if raw is None:
        return NewsConfig()
    if not isinstance(raw, dict):
        raise ValueError("[collectors.news] must be a table")

    enabled = _bool(raw.get("enabled", False), "collectors.news.enabled")
    provider = raw.get("provider", "newsapi")
    if not isinstance(provider, str) or provider not in NEWS_PROVIDERS:
        raise ValueError("collectors.news.provider must be 'newsapi' or 'gnews'")

    default_mode = "top-headlines"
    mode = raw.get("mode", default_mode)
    allowed_modes = NEWSAPI_MODES if provider == "newsapi" else GNEWS_MODES
    if not isinstance(mode, str) or mode not in allowed_modes:
        allowed = " or ".join(repr(value) for value in sorted(allowed_modes))
        raise ValueError(f"collectors.news.mode must be {allowed} for provider {provider}")

    query = raw.get("query", "")
    if not isinstance(query, str):
        raise ValueError("collectors.news.query must be a string")
    query = query.strip()
    query_limit = 500 if provider == "newsapi" else 200
    if len(query) > query_limit:
        raise ValueError(f"collectors.news.query must be <= {query_limit} characters for provider {provider}")
    if provider == "gnews" and mode == "search" and not query:
        raise ValueError("collectors.news.query is required for GNews search")

    sources = _csv(raw.get("sources", ""), "collectors.news.sources")
    search_in = _search_in(raw.get("search_in", ""))
    domains = _csv(raw.get("domains", ""), "collectors.news.domains")
    exclude_domains = _csv(raw.get("exclude_domains", ""), "collectors.news.exclude_domains")
    from_date = _optional_iso8601(raw.get("from", ""), "collectors.news.from")
    to_date = _optional_iso8601(raw.get("to", ""), "collectors.news.to")

    category_raw = raw.get("category", "")
    if not isinstance(category_raw, str):
        raise ValueError("collectors.news.category must be a string")
    category = category_raw.strip().lower()

    if provider == "newsapi":
        if mode == "everything" and sources and len(sources.split(",")) > 20:
            raise ValueError("collectors.news.sources must contain at most 20 comma-separated values in everything mode")
        country = _optional_choice(raw.get("country", "fr"), "collectors.news.country", NEWSAPI_COUNTRIES)
        if category and category not in NEWSAPI_CATEGORIES:
            raise ValueError("collectors.news.category is unsupported for NewsAPI")
        if mode == "top-headlines" and sources and (country or category):
            raise ValueError("collectors.news.sources cannot be combined with country or category in NewsAPI top-headlines mode")
        lang = _optional_choice(raw.get("lang", "fr"), "collectors.news.lang", NEWSAPI_LANGUAGES)
        sort_by = raw.get("sort_by", "publishedAt")
        if not isinstance(sort_by, str) or sort_by not in NEWSAPI_SORT_ORDERS:
            raise ValueError("collectors.news.sort_by is unsupported for NewsAPI")
        nullable = ""
    else:
        if sources or domains or exclude_domains:
            raise ValueError("collectors.news.sources/domains/exclude_domains are not supported by GNews")
        country = _optional_two_letter_code(raw.get("country", "fr"), "collectors.news.country")
        lang = _optional_two_letter_code(raw.get("lang", "fr"), "collectors.news.lang")
        if category and category not in GNEWS_CATEGORIES:
            raise ValueError("collectors.news.category is unsupported for GNews")
        sort_by = raw.get("sort_by", "publishedAt")
        if not isinstance(sort_by, str) or sort_by not in GNEWS_SORT_ORDERS:
            raise ValueError("collectors.news.sort_by is unsupported for GNews")
        nullable = _csv(raw.get("nullable", ""), "collectors.news.nullable")
        if nullable and any(field not in GNEWS_NULLABLE_FIELDS for field in nullable.split(",")):
            raise ValueError("collectors.news.nullable contains an unsupported GNews field")

    default_key_path = DEFAULT_NEWSAPI_KEY_PATH if provider == "newsapi" else DEFAULT_GNEWS_KEY_PATH
    api_key_file = raw.get("api_key_file", str(default_key_path))
    if not isinstance(api_key_file, str) or not api_key_file.strip():
        raise ValueError("collectors.news.api_key_file must be a non-empty string")

    return NewsConfig(
        enabled=enabled,
        provider=provider,
        mode=mode,
        query=query,
        sources=sources,
        country=country,
        category=category,
        search_in=search_in,
        domains=domains,
        exclude_domains=exclude_domains,
        from_date=from_date,
        to_date=to_date,
        lang=lang,
        sort_by=sort_by,
        nullable=nullable,
        max_articles=_positive_int(raw.get("max_articles", 10), "collectors.news.max_articles", maximum=100),
        interval=_positive_int(raw.get("interval", 1800), "collectors.news.interval", minimum=300, maximum=86400),
        request_timeout=_positive_int(raw.get("request_timeout", 15), "collectors.news.request_timeout", maximum=60),
        api_key_file=Path(api_key_file.strip()),
    )


def mini_server_config_from_mapping(raw: object) -> MiniServerConfig:
    """Parse the configurable Agent HTTP target for the first monitored server."""
    if raw is None:
        return MiniServerConfig()
    if not isinstance(raw, dict):
        raise ValueError("[collectors.mini_server] must be a table")

    enabled = _bool(raw.get("enabled", False), "collectors.mini_server.enabled")
    host = raw.get("host", "")
    if not isinstance(host, str):
        raise ValueError("collectors.mini_server.host must be a string")
    host = host.strip()
    if enabled and not host:
        raise ValueError("enabled mini-server collector requires host")
    if host and (len(host) > 255 or any(ch.isspace() for ch in host) or ":" in host or "/" in host):
        raise ValueError("collectors.mini_server.host must be an IP address or hostname without scheme/path")

    return MiniServerConfig(
        enabled=enabled,
        host=host,
        port=_positive_int(raw.get("port", 8765), "collectors.mini_server.port", maximum=65535),
        poll_interval=_positive_int(raw.get("poll_interval", 2), "collectors.mini_server.poll_interval", maximum=300),
        request_timeout=_positive_int(raw.get("request_timeout", 2), "collectors.mini_server.request_timeout", maximum=60),
        offline_after_failures=_positive_int(
            raw.get("offline_after_failures", 3),
            "collectors.mini_server.offline_after_failures",
            maximum=60,
        ),
        max_snapshot_age=_positive_int(
            raw.get("max_snapshot_age", 10),
            "collectors.mini_server.max_snapshot_age",
            maximum=3600,
        ),
    )


def printer_config_from_mapping(raw: object) -> PrinterConfig:
    if raw is None:
        return PrinterConfig()
    if not isinstance(raw, dict):
        raise ValueError("[collectors.printer] must be a table")

    enabled = _bool(raw.get("enabled", False), "collectors.printer.enabled")
    devices_raw = raw.get("devices", [])
    if not isinstance(devices_raw, list):
        raise ValueError("collectors.printer.devices must be an array of tables")

    devices: list[PrinterDeviceConfig] = []
    seen_ids: set[str] = set()
    for index, item in enumerate(devices_raw):
        prefix = f"collectors.printer.devices[{index}]"
        if not isinstance(item, dict):
            raise ValueError(f"{prefix} must be a table")

        device_id = item.get("id")
        driver = item.get("driver", "elegoo_cc2")
        host = item.get("host")
        for value, name in (
            (device_id, "id"),
            (driver, "driver"),
            (host, "host"),
        ):
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{prefix}.{name} must be a non-empty string")

        normalized_id = device_id.strip()
        if any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for ch in normalized_id):
            raise ValueError(f"{prefix}.id may contain only letters, digits, '-' and '_'")
        if normalized_id in seen_ids:
            raise ValueError(f"duplicate printer id: {normalized_id}")
        seen_ids.add(normalized_id)

        normalized_driver = driver.strip().lower()
        if normalized_driver != "elegoo_cc2":
            raise ValueError(f"{prefix}.driver is unsupported")

        access_code_file = item.get(
            "access_code_file",
            str(DEFAULT_PRINTER_SECRET_DIR / f"{normalized_id}_access_code"),
        )
        if not isinstance(access_code_file, str) or not access_code_file.strip():
            raise ValueError(f"{prefix}.access_code_file must be a non-empty string")

        reconnect_min = _positive_int(
            item.get("reconnect_min_delay", 2),
            f"{prefix}.reconnect_min_delay",
            maximum=300,
        )
        reconnect_max = _positive_int(
            item.get("reconnect_max_delay", 30),
            f"{prefix}.reconnect_max_delay",
            maximum=600,
        )
        if reconnect_min > reconnect_max:
            raise ValueError(f"{prefix}.reconnect_min_delay must be <= reconnect_max_delay")

        devices.append(
            PrinterDeviceConfig(
                id=normalized_id,
                driver=normalized_driver,
                host=host.strip(),
                access_code_file=Path(access_code_file.strip()),
                enabled=_bool(item.get("enabled", True), f"{prefix}.enabled"),
                port=_positive_int(item.get("port", 1883), f"{prefix}.port", maximum=65535),
                reconnect_min_delay=reconnect_min,
                reconnect_max_delay=reconnect_max,
            )
        )

    if enabled and not any(device.enabled for device in devices):
        raise ValueError("enabled printer collector requires at least one enabled device")

    return PrinterConfig(
        enabled=enabled,
        devices=tuple(devices),
        poll_interval=_positive_int(
            raw.get("poll_interval", 5),
            "collectors.printer.poll_interval",
            minimum=2,
            maximum=300,
        ),
        request_timeout=_positive_int(
            raw.get("request_timeout", 8),
            "collectors.printer.request_timeout",
            minimum=2,
            maximum=60,
        ),
        thumbnail_max_base64_bytes=_positive_int(
            raw.get("thumbnail_max_base64_bytes", 2_000_000),
            "collectors.printer.thumbnail_max_base64_bytes",
            minimum=1024,
            maximum=16_000_000,
        ),
        thumbnail_max_png_bytes=_positive_int(
            raw.get("thumbnail_max_png_bytes", 1_500_000),
            "collectors.printer.thumbnail_max_png_bytes",
            minimum=1024,
            maximum=12_000_000,
        ),
        thumbnail_max_pixels=_positive_int(
            raw.get("thumbnail_max_pixels", 1_000_000),
            "collectors.printer.thumbnail_max_pixels",
            minimum=4096,
            maximum=16_000_000,
        ),
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
        news=news_config_from_mapping(collectors_raw.get("news")),
        mini_server=mini_server_config_from_mapping(collectors_raw.get("mini_server")),
        printer=printer_config_from_mapping(collectors_raw.get("printer")),
    )
