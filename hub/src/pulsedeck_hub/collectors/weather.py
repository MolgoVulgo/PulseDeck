"""OpenWeather One Call 4.0 collector for PulseDeck."""

from __future__ import annotations

from dataclasses import dataclass
import json
import logging
import threading
import time
from typing import TYPE_CHECKING, Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

from ..config import WeatherConfig
from ..mqtt.payloads import encode_payload, source_availability_payload

if TYPE_CHECKING:
    from ..mqtt.client import HubMQTTClient


LOG = logging.getLogger(__name__)
SOURCE = "openweather-onecall-4"
API_ROOT = "https://api.openweathermap.org/data/4.0/onecall"
ALLOWED_API_HOST = "api.openweathermap.org"


class WeatherError(RuntimeError):
    """A sanitized weather provider or publication failure."""


@dataclass(frozen=True, slots=True)
class WeatherResponse:
    data: list[dict[str, Any]]
    latitude: float
    longitude: float
    timezone: str
    timezone_offset: int
    next_url: str | None = None


def _number(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def _nested_precip(record: dict[str, Any], kind: str) -> int | float | None:
    raw = record.get(kind)
    if not isinstance(raw, dict):
        return None
    return _number(raw.get("1h"))


def _condition(record: dict[str, Any]) -> dict[str, object] | None:
    raw = record.get("weather")
    if not isinstance(raw, list) or not raw or not isinstance(raw[0], dict):
        return None
    item = raw[0]
    result: dict[str, object] = {}
    for key in ("id", "main", "description", "icon"):
        value = item.get(key)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            result[key] = value
    return result or None


def _location(response: WeatherResponse, configured_name: str) -> dict[str, object]:
    result: dict[str, object] = {
        "lat": response.latitude,
        "lon": response.longitude,
        "timezone": response.timezone,
        "timezone_offset": response.timezone_offset,
    }
    if configured_name:
        result["name"] = configured_name
    return result


def normalize_current(response: WeatherResponse, configured_name: str) -> dict[str, object]:
    if not response.data:
        raise WeatherError("current response contains no data")
    record = response.data[0]
    source_ts = record.get("dt")
    if not isinstance(source_ts, int):
        raise WeatherError("current response has no valid dt")

    data: dict[str, object] = {}
    mapping = {
        "temp": "temperature_c",
        "feels_like": "feels_like_c",
        "pressure": "pressure_hpa",
        "humidity": "humidity_pct",
        "dew_point": "dew_point_c",
        "uvi": "uvi",
        "clouds": "clouds_pct",
        "visibility": "visibility_m",
        "wind_speed": "wind_mps",
        "wind_gust": "wind_gust_mps",
        "wind_deg": "wind_deg",
        "sunrise": "sunrise",
        "sunset": "sunset",
    }
    for source_key, target_key in mapping.items():
        value = _number(record.get(source_key))
        if value is not None:
            data[target_key] = value

    rain = _nested_precip(record, "rain")
    snow = _nested_precip(record, "snow")
    if rain is not None:
        data["rain_1h_mm"] = rain
    if snow is not None:
        data["snow_1h_mm"] = snow
    condition = _condition(record)
    if condition:
        data["condition"] = condition

    alerts = record.get("alerts")
    alert_ids = [item for item in alerts if isinstance(item, str)] if isinstance(alerts, list) else []

    return {
        "schema": 1,
        "source": SOURCE,
        "ts": int(time.time()),
        "source_ts": source_ts,
        "location": _location(response, configured_name),
        "data": data,
        "alert_ids": alert_ids,
    }


def normalize_hourly(response: WeatherResponse, configured_name: str, hours: int) -> dict[str, object]:
    normalized: list[dict[str, object]] = []
    for record in response.data[:hours]:
        source_ts = record.get("dt")
        if not isinstance(source_ts, int):
            continue
        item: dict[str, object] = {"ts": source_ts}
        mapping = {
            "temp": "temperature_c",
            "feels_like": "feels_like_c",
            "pressure": "pressure_hpa",
            "humidity": "humidity_pct",
            "dew_point": "dew_point_c",
            "uvi": "uvi",
            "clouds": "clouds_pct",
            "visibility": "visibility_m",
            "wind_speed": "wind_mps",
            "wind_gust": "wind_gust_mps",
            "wind_deg": "wind_deg",
        }
        for source_key, target_key in mapping.items():
            value = _number(record.get(source_key))
            if value is not None:
                item[target_key] = value
        pop = _number(record.get("pop"))
        if pop is not None:
            item["pop_pct"] = round(float(pop) * 100)
        rain = _nested_precip(record, "rain")
        snow = _nested_precip(record, "snow")
        if rain is not None:
            item["rain_1h_mm"] = rain
        if snow is not None:
            item["snow_1h_mm"] = snow
        condition = _condition(record)
        if condition:
            item["condition"] = condition
        normalized.append(item)

    return {
        "schema": 1,
        "source": SOURCE,
        "ts": int(time.time()),
        "location": _location(response, configured_name),
        "hours": normalized,
    }


def normalize_daily(response: WeatherResponse, configured_name: str, days: int) -> dict[str, object]:
    normalized: list[dict[str, object]] = []
    for record in response.data[:days]:
        source_ts = record.get("dt")
        if not isinstance(source_ts, int):
            continue
        item: dict[str, object] = {"ts": source_ts}
        temp = record.get("temp")
        if isinstance(temp, dict):
            for key in ("day", "min", "max", "night", "eve", "morn"):
                value = _number(temp.get(key))
                if value is not None:
                    item[f"temperature_{key}_c"] = value
        feels = record.get("feels_like")
        if isinstance(feels, dict):
            for key in ("day", "night", "eve", "morn"):
                value = _number(feels.get(key))
                if value is not None:
                    item[f"feels_like_{key}_c"] = value
        mapping = {
            "pressure": "pressure_hpa",
            "humidity": "humidity_pct",
            "dew_point": "dew_point_c",
            "uvi": "uvi",
            "clouds": "clouds_pct",
            "wind_speed": "wind_mps",
            "wind_gust": "wind_gust_mps",
            "wind_deg": "wind_deg",
            "sunrise": "sunrise",
            "sunset": "sunset",
            "moonrise": "moonrise",
            "moonset": "moonset",
            "moon_phase": "moon_phase",
        }
        for source_key, target_key in mapping.items():
            value = _number(record.get(source_key))
            if value is not None:
                item[target_key] = value
        pop = _number(record.get("pop"))
        if pop is not None:
            item["pop_pct"] = round(float(pop) * 100)
        for kind in ("rain", "snow"):
            raw_precip = record.get(kind)
            if isinstance(raw_precip, (int, float)) and not isinstance(raw_precip, bool):
                item[f"{kind}_mm"] = raw_precip
            elif isinstance(raw_precip, dict):
                one_hour = _number(raw_precip.get("1h"))
                if one_hour is not None:
                    item[f"{kind}_1h_mm"] = one_hour
        condition = _condition(record)
        if condition:
            item["condition"] = condition
        normalized.append(item)

    return {
        "schema": 1,
        "source": SOURCE,
        "ts": int(time.time()),
        "location": _location(response, configured_name),
        "days": normalized,
    }


class OpenWeatherClient:
    def __init__(self, config: WeatherConfig) -> None:
        self.config = config

    def _api_key(self) -> str:
        try:
            key = self.config.api_key_file.read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise WeatherError(f"API key file unavailable: {self.config.api_key_file}") from exc
        if not key:
            raise WeatherError("OpenWeather API key is empty")
        return key

    def _request(self, path_or_url: str, *, start: int | None = None) -> WeatherResponse:
        if path_or_url.startswith("https://"):
            parsed = urlparse(path_or_url)
            if parsed.scheme != "https" or parsed.hostname != ALLOWED_API_HOST:
                raise WeatherError("provider returned an unsafe pagination URL")
            url = path_or_url
        else:
            params: dict[str, object] = {
                "lat": self.config.latitude,
                "lon": self.config.longitude,
                "units": "metric",
                "lang": self.config.lang,
                "appid": self._api_key(),
            }
            if start is not None:
                params["start"] = start
            url = f"{API_ROOT}/{path_or_url}?{urlencode(params)}"

        request = Request(url, headers={"Accept": "application/json", "User-Agent": "PulseDeck/0.2"})
        try:
            with urlopen(request, timeout=self.config.request_timeout) as response:  # noqa: S310
                body = response.read()
        except HTTPError as exc:
            raise WeatherError(f"OpenWeather HTTP {exc.code}") from exc
        except URLError as exc:
            reason = getattr(exc, "reason", None)
            raise WeatherError(f"OpenWeather network error: {type(reason).__name__ if reason else 'unknown'}") from exc
        except TimeoutError as exc:
            raise WeatherError("OpenWeather request timed out") from exc

        try:
            raw = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise WeatherError("OpenWeather returned invalid JSON") from exc
        if not isinstance(raw, dict):
            raise WeatherError("OpenWeather returned an unexpected response")
        data = raw.get("data")
        if not isinstance(data, list):
            raise WeatherError("OpenWeather response contains no data array")

        lat = raw.get("lat", self.config.latitude)
        lon = raw.get("lon", self.config.longitude)
        timezone = raw.get("timezone", "")
        timezone_offset = raw.get("timezone_offset", 0)
        if not isinstance(lat, (int, float)) or isinstance(lat, bool):
            raise WeatherError("OpenWeather response has invalid latitude")
        if not isinstance(lon, (int, float)) or isinstance(lon, bool):
            raise WeatherError("OpenWeather response has invalid longitude")
        if not isinstance(timezone, str) or not isinstance(timezone_offset, int):
            raise WeatherError("OpenWeather response has invalid timezone metadata")
        next_url = raw.get("next")
        if next_url is not None and not isinstance(next_url, str):
            next_url = None
        clean_data = [item for item in data if isinstance(item, dict)]
        return WeatherResponse(clean_data, float(lat), float(lon), timezone, timezone_offset, next_url)

    def current(self) -> WeatherResponse:
        return self._request("current")

    def timeline(self, step: str, count: int) -> WeatherResponse:
        now = int(time.time())
        first = self._request(f"timeline/{step}", start=now)
        records = list(first.data)
        seen = {item.get("dt") for item in records}
        next_url = first.next_url
        pages = 1
        while len(records) < count and next_url and pages < 6:
            page = self._request(next_url)
            for item in page.data:
                stamp = item.get("dt")
                if stamp not in seen:
                    records.append(item)
                    seen.add(stamp)
            next_url = page.next_url
            pages += 1
        tolerance = 86400 if step == "1day" else 3600
        future = [item for item in records if isinstance(item.get("dt"), int) and item["dt"] >= now - tolerance]
        future.sort(key=lambda item: int(item["dt"]))
        return WeatherResponse(
            future[:count],
            first.latitude,
            first.longitude,
            first.timezone,
            first.timezone_offset,
            next_url,
        )


class WeatherCollector:
    def __init__(self, config: WeatherConfig, mqtt_client: "HubMQTTClient") -> None:
        self.config = config
        self.mqtt = mqtt_client
        self.provider = OpenWeatherClient(config)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="weather-collector", daemon=True)
        self._last_success: int | None = None

    def start(self) -> None:
        LOG.info(
            "Starting Weather collector for %s (%.4f, %.4f)",
            self.config.location_name or "configured location",
            self.config.latitude,
            self.config.longitude,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=float(self.config.request_timeout) + 2.0)
        self._publish_availability("offline", reason="collector_stopped")

    def _publish(self, suffix: str, payload: dict[str, object]) -> None:
        if not self.mqtt.publish_retained(suffix, encode_payload(payload)):
            raise WeatherError(f"MQTT publish unavailable for {suffix}")

    def _publish_availability(self, state: str, *, reason: str | None = None) -> None:
        payload = source_availability_payload(
            state,
            source=SOURCE,
            last_success=self._last_success,
            reason=reason,
        )
        if not self.mqtt.publish_retained("weather/availability", payload):
            LOG.debug("Weather availability not published because MQTT is unavailable")

    def _fetch_current(self) -> None:
        response = self.provider.current()
        self._publish("weather/current", normalize_current(response, self.config.location_name))
        self._last_success = int(time.time())
        self._publish_availability("online")
        LOG.info("Weather current updated")

    def _fetch_hourly(self) -> None:
        response = self.provider.timeline("1h", self.config.hourly_hours)
        if len(response.data) < self.config.hourly_hours:
            LOG.warning("Weather hourly returned %d/%d records", len(response.data), self.config.hourly_hours)
        self._publish("weather/hourly", normalize_hourly(response, self.config.location_name, self.config.hourly_hours))
        LOG.info("Weather hourly updated: %d records", len(response.data))

    def _fetch_daily(self) -> None:
        response = self.provider.timeline("1day", self.config.daily_days)
        if len(response.data) < self.config.daily_days:
            LOG.warning("Weather daily returned %d/%d records", len(response.data), self.config.daily_days)
        self._publish("weather/daily", normalize_daily(response, self.config.location_name, self.config.daily_days))
        LOG.info("Weather daily updated: %d records", len(response.data))

    def _run(self) -> None:
        self._publish_availability("offline", reason="starting")
        next_current = next_hourly = next_daily = 0.0
        retry_delay = 60.0

        while not self._stop.is_set():
            if not self.mqtt.connected.wait(timeout=5.0):
                continue

            now = time.monotonic()
            current_failed = False
            if now >= next_current:
                try:
                    self._fetch_current()
                    next_current = now + self.config.current_interval
                except WeatherError as exc:
                    LOG.warning("Weather current failed: %s", exc)
                    self._publish_availability("offline", reason=str(exc))
                    next_current = now + retry_delay
                    current_failed = True

            if current_failed:
                next_hourly = max(next_hourly, next_current)
                next_daily = max(next_daily, next_current)
            else:
                if now >= next_hourly:
                    try:
                        self._fetch_hourly()
                        next_hourly = now + self.config.hourly_interval
                    except WeatherError as exc:
                        LOG.warning("Weather hourly failed: %s", exc)
                        next_hourly = now + retry_delay

                if now >= next_daily:
                    try:
                        self._fetch_daily()
                        next_daily = now + self.config.daily_interval
                    except WeatherError as exc:
                        LOG.warning("Weather daily failed: %s", exc)
                        next_daily = now + retry_delay

            deadline = min(next_current, next_hourly, next_daily)
            delay = max(1.0, min(30.0, deadline - time.monotonic()))
            self._stop.wait(delay)
