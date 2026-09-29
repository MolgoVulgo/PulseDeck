"""HTTP routes for the LAN-only PulseDeck administration interface."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import shutil
import time
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

from .. import __version__
from ..collectors.news import NewsError, build_news_client, normalize_news
from ..collectors.weather import OpenWeatherClient, WeatherError, geocode_locations
from ..config import (
    DEFAULT_GNEWS_KEY_PATH,
    DEFAULT_NEWSAPI_KEY_PATH,
    DEFAULT_OPENWEATHER_KEY_PATH,
    DEFAULT_PRINTER_SECRET_DIR,
    NewsConfig,
    PrinterConfig,
    PrinterDeviceConfig,
    WeatherConfig,
    news_config_from_mapping,
    printer_config_from_mapping,
    weather_config_from_mapping,
)
from ..logging_setup import LOG_SERVICES, recent_logs
from ..printers.elegoo_cc2 import ElegooCC2Client, PrinterError, extract_job_identity, normalize_job, normalize_status
from ..update import load_update_install_status, queue_update_request
from .catalog import build_service_catalog
from .security import (
    COOKIE_NAME,
    PASSWORD_HASH_PATH,
    SESSION_KEY_PATH,
    SESSION_TTL,
    ensure_session_key,
    hash_password,
    make_session,
    verify_password,
    verify_session,
)
from .storage import update_news_config, update_printer_config, update_secret, update_weather_config
from .ui import ADMIN_HTML


LOG = logging.getLogger(__name__)


def _json_error(status: int, message: str) -> HTTPException:
    return HTTPException(status_code=status, detail=message)


def _read_password_hash() -> str:
    try:
        return PASSWORD_HASH_PATH.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise _json_error(503, "Admin credentials are not initialized") from exc


def _require_auth(request: Request, session_key: bytes) -> None:
    token = request.cookies.get(COOKIE_NAME, "")
    if not token or not verify_session(token, session_key):
        raise _json_error(401, "Authentication required")


def _require_mutation_guard(request: Request, session_key: bytes) -> None:
    _require_auth(request, session_key)
    if request.headers.get("x-pulsedeck-csrf") != "1":
        raise _json_error(403, "Missing request guard")
    origin = request.headers.get("origin")
    host = request.headers.get("host")
    if origin and host and origin.rstrip("/") != f"{request.url.scheme}://{host}":
        raise _json_error(403, "Cross-origin request rejected")


def _configured_secret(path: Path) -> str | None:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


def _candidate_weather(runtime: Any, body: dict[str, Any]) -> tuple[WeatherConfig, str | None]:
    current = runtime.config.weather
    raw = {
        "enabled": body.get("enabled", current.enabled),
        "provider": "openweather-onecall-4",
        "latitude": body.get("latitude", current.latitude),
        "longitude": body.get("longitude", current.longitude),
        "location_name": body.get("location_name", current.location_name),
        "api_key_file": str(current.api_key_file or DEFAULT_OPENWEATHER_KEY_PATH),
        "lang": body.get("lang", current.lang),
        "current_interval": body.get("current_interval", current.current_interval),
        "hourly_interval": body.get("hourly_interval", current.hourly_interval),
        "daily_interval": body.get("daily_interval", current.daily_interval),
        "hourly_hours": body.get("hourly_hours", current.hourly_hours),
        "daily_days": body.get("daily_days", current.daily_days),
        "request_timeout": body.get("request_timeout", current.request_timeout),
    }
    try:
        candidate = weather_config_from_mapping(raw)
    except ValueError as exc:
        raise _json_error(400, str(exc)) from exc
    provided = body.get("api_key")
    if provided is not None and not isinstance(provided, str):
        raise _json_error(400, "api_key must be a string or null")
    key = provided.strip() if isinstance(provided, str) and provided.strip() else _configured_secret(current.api_key_file)
    if candidate.enabled and not key:
        raise _json_error(400, "OpenWeather API key is required when Weather is enabled")
    return candidate, key


def _test_weather(candidate: WeatherConfig, key: str) -> dict[str, Any]:
    client = OpenWeatherClient(candidate, api_key=key)
    current = client.current()
    hourly = client.timeline("1h", 1)
    if not current.data:
        raise WeatherError("current response contains no data")
    return {
        "ok": True,
        "temperature_c": current.data[0].get("temp"),
        "timezone": current.timezone,
        "hourly_records": len(hourly.data),
    }


def _news_key_path(provider: str) -> Path:
    return DEFAULT_GNEWS_KEY_PATH if provider == "gnews" else DEFAULT_NEWSAPI_KEY_PATH


def _provider_label(provider: str) -> str:
    return "GNews" if provider == "gnews" else "NewsAPI"


def _candidate_news(runtime: Any, body: dict[str, Any]) -> tuple[NewsConfig, str | None]:
    current = runtime.config.news
    provider = body.get("provider", current.provider)
    if not isinstance(provider, str):
        raise _json_error(400, "provider must be a string")
    candidate_key_path = current.api_key_file if provider == current.provider else _news_key_path(provider)
    raw = {
        "enabled": body.get("enabled", current.enabled),
        "provider": provider,
        "mode": body.get("mode", current.mode),
        "query": body.get("query", current.query),
        "sources": body.get("sources", current.sources),
        "country": body.get("country", current.country),
        "category": body.get("category", current.category),
        "search_in": body.get("search_in", current.search_in),
        "domains": body.get("domains", current.domains),
        "exclude_domains": body.get("exclude_domains", current.exclude_domains),
        "from": body.get("from", current.from_date),
        "to": body.get("to", current.to_date),
        "lang": body.get("lang", current.lang),
        "sort_by": body.get("sort_by", current.sort_by),
        "nullable": body.get("nullable", current.nullable),
        "max_articles": body.get("max_articles", current.max_articles),
        "interval": body.get("interval", current.interval),
        "request_timeout": body.get("request_timeout", current.request_timeout),
        "api_key_file": str(candidate_key_path),
    }
    try:
        candidate = news_config_from_mapping(raw)
    except ValueError as exc:
        raise _json_error(400, str(exc)) from exc
    provided = body.get("api_key")
    if provided is not None and not isinstance(provided, str):
        raise _json_error(400, "api_key must be a string or null")
    key = provided.strip() if isinstance(provided, str) and provided.strip() else _configured_secret(candidate.api_key_file)
    if candidate.enabled and not key:
        raise _json_error(400, f"{_provider_label(candidate.provider)} API key is required when News is enabled")
    return candidate, key


def _test_news(candidate: NewsConfig, key: str) -> dict[str, Any]:
    raw = build_news_client(candidate, api_key=key).fetch()
    payload = normalize_news(raw, candidate)
    articles = payload.get("articles")
    count = len(articles) if isinstance(articles, list) else 0
    first_title = articles[0].get("title") if count and isinstance(articles[0], dict) else None
    return {
        "ok": True,
        "provider": candidate.provider,
        "provider_label": _provider_label(candidate.provider),
        "article_count": count,
        "total_results": payload.get("total_results"),
        "first_title": first_title,
    }



def _printer_device_raw(device: PrinterDeviceConfig) -> dict[str, Any]:
    return {
        "id": device.id,
        "driver": device.driver,
        "host": device.host,
        "access_code_file": str(device.access_code_file),
        "enabled": device.enabled,
        "port": device.port,
        "reconnect_min_delay": device.reconnect_min_delay,
        "reconnect_max_delay": device.reconnect_max_delay,
    }


def _candidate_printer(
    runtime: Any,
    body: dict[str, Any],
) -> tuple[PrinterConfig, dict[str, str | None], dict[Path, str]]:
    current = runtime.config.printer
    current_by_id = {device.id: device for device in current.devices}
    devices_body = body.get("devices")
    if devices_body is None:
        devices_body = [_printer_device_raw(device) for device in current.devices]
    if not isinstance(devices_body, list):
        raise _json_error(400, "devices must be an array")

    raw_devices: list[dict[str, Any]] = []
    provided_codes: dict[Path, str] = {}
    for index, item in enumerate(devices_body):
        if not isinstance(item, dict):
            raise _json_error(400, f"devices[{index}] must be an object")
        device_id = item.get("id")
        if not isinstance(device_id, str) or not device_id.strip():
            raise _json_error(400, f"devices[{index}].id must be a non-empty string")
        normalized_id = device_id.strip()
        if any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for ch in normalized_id):
            raise _json_error(400, f"devices[{index}].id contains unsupported characters")

        previous = current_by_id.get(normalized_id)
        secret_path = previous.access_code_file if previous is not None else DEFAULT_PRINTER_SECRET_DIR / f"{normalized_id}_access_code"
        provided = item.get("access_code")
        if provided is not None and not isinstance(provided, str):
            raise _json_error(400, f"devices[{index}].access_code must be a string or null")
        if isinstance(provided, str) and provided.strip():
            provided_codes[secret_path] = provided.strip()

        raw_devices.append(
            {
                "id": normalized_id,
                "driver": item.get("driver", previous.driver if previous else "elegoo_cc2"),
                "host": item.get("host", previous.host if previous else ""),
                "access_code_file": str(secret_path),
                "enabled": item.get("enabled", previous.enabled if previous else True),
                "port": item.get("port", previous.port if previous else 1883),
                "reconnect_min_delay": item.get(
                    "reconnect_min_delay",
                    previous.reconnect_min_delay if previous else 2,
                ),
                "reconnect_max_delay": item.get(
                    "reconnect_max_delay",
                    previous.reconnect_max_delay if previous else 30,
                ),
            }
        )

    raw = {
        "enabled": body.get("enabled", current.enabled),
        "poll_interval": body.get("poll_interval", current.poll_interval),
        "request_timeout": body.get("request_timeout", current.request_timeout),
        "thumbnail_max_base64_bytes": current.thumbnail_max_base64_bytes,
        "thumbnail_max_png_bytes": current.thumbnail_max_png_bytes,
        "thumbnail_max_pixels": current.thumbnail_max_pixels,
        "devices": raw_devices,
    }
    try:
        candidate = printer_config_from_mapping(raw)
    except ValueError as exc:
        raise _json_error(400, str(exc)) from exc

    access_codes: dict[str, str | None] = {}
    for device in candidate.devices:
        code = provided_codes.get(device.access_code_file)
        if code is None:
            code = _configured_secret(device.access_code_file)
        access_codes[device.id] = code
        if candidate.enabled and device.enabled and not code:
            raise _json_error(400, f"Access code is required for enabled printer {device.id}")
    return candidate, access_codes, provided_codes


def _probe_printer(device: PrinterDeviceConfig, access_code: str, request_timeout: int) -> dict[str, Any]:
    client = ElegooCC2Client(device, access_code, request_timeout=request_timeout)
    client.start()
    try:
        result = client.request(1002, {})
        serial = client.serial_number
    finally:
        client.stop()
    _filename, _current_layer, total_hint = extract_job_identity(result)
    return {
        "ok": True,
        "printer_id": device.id,
        "serial": serial,
        "status": normalize_status(result, printer_id=device.id),
        "job": normalize_job(
            result,
            printer_id=device.id,
            total_layers=total_hint,
            thumbnail_available=False,
        ),
    }


def _printer_runtime_snapshot(runtime: Any) -> dict[str, Any]:
    messages = _retained_messages(runtime, "printer")
    by_suffix = {message["suffix"]: message for message in messages}
    devices: list[dict[str, Any]] = []
    enabled_states: list[str] = []

    for device in runtime.config.printer.devices:
        prefix = f"printer/{device.id}"
        availability_message = by_suffix.get(f"{prefix}/availability")
        status_message = by_suffix.get(f"{prefix}/status")
        job_message = by_suffix.get(f"{prefix}/job")
        availability = availability_message.get("payload") if availability_message else None
        status = status_message.get("payload") if status_message else None
        job = job_message.get("payload") if job_message else None

        if not device.enabled:
            state = "disabled"
        elif isinstance(availability, dict) and isinstance(availability.get("state"), str):
            state = availability["state"]
        else:
            state = "starting"
        if device.enabled:
            enabled_states.append(state)

        devices.append(
            {
                "id": device.id,
                "driver": device.driver,
                "host": device.host,
                "serial": availability.get("serial") if isinstance(availability, dict) else None,
                "enabled": device.enabled,
                "state": state,
                "availability": availability if isinstance(availability, dict) else None,
                "status": status if isinstance(status, dict) else None,
                "job": job if isinstance(job, dict) else None,
            }
        )

    if not runtime.config.printer.enabled:
        overall = "disabled"
    elif not enabled_states:
        overall = "disabled"
    elif all(state == "online" for state in enabled_states):
        overall = "online"
    elif any(state == "online" for state in enabled_states):
        overall = "degraded"
    elif any(state == "starting" for state in enabled_states):
        overall = "starting"
    else:
        overall = "offline"

    return {
        "state": overall,
        "enabled": runtime.config.printer.enabled,
        "configured_devices": len(runtime.config.printer.devices),
        "enabled_devices": len(enabled_states),
        "online_devices": sum(state == "online" for state in enabled_states),
        "devices": devices,
    }

def _retained_messages(runtime: Any, prefix: str) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    for suffix, entry in sorted(runtime.mqtt_client.retained_snapshot(prefix).items()):
        raw_payload = entry.get("payload")
        payload: object = raw_payload
        if isinstance(raw_payload, str):
            try:
                payload = json.loads(raw_payload)
            except json.JSONDecodeError:
                payload = raw_payload
        messages.append(
            {
                "suffix": suffix,
                "topic": entry.get("topic"),
                "published_at": entry.get("published_at"),
                "qos": entry.get("qos"),
                "binary": bool(entry.get("binary", False)),
                "size": entry.get("size"),
                "payload": payload,
            }
        )
    return messages


def _system_metrics() -> dict[str, Any]:
    memory_available = memory_total = 0
    try:
        values: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, raw = line.split(":", 1)
            values[key] = int(raw.strip().split()[0])
        memory_available = values.get("MemAvailable", 0) // 1024
        memory_total = values.get("MemTotal", 0) // 1024
    except (OSError, ValueError):
        pass
    disk = shutil.disk_usage("/")
    return {
        "memory_available_mb": memory_available,
        "memory_total_mb": memory_total,
        "disk_free_gb": round(disk.free / (1024**3), 1),
        "disk_total_gb": round(disk.total / (1024**3), 1),
    }


def install_routes(app: FastAPI, runtime: Any) -> None:
    session_key = ensure_session_key(SESSION_KEY_PATH)

    @app.middleware("http")
    async def security_headers(request: Request, call_next):  # type: ignore[no-untyped-def]
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
        return response

    @app.get("/", response_class=HTMLResponse)
    def index() -> str:
        return ADMIN_HTML

    @app.get("/api/health")
    def health() -> dict[str, Any]:
        return {"ok": True, "version": __version__}

    @app.post("/api/auth/login")
    async def login(request: Request) -> Response:
        body = await request.json()
        password = body.get("password") if isinstance(body, dict) else None
        if not isinstance(password, str) or not verify_password(password, _read_password_hash()):
            time.sleep(0.15)
            raise _json_error(401, "Invalid credentials")
        response = JSONResponse({"ok": True})
        response.set_cookie(
            COOKIE_NAME,
            make_session(session_key),
            max_age=SESSION_TTL,
            httponly=True,
            samesite="strict",
            secure=False,
            path="/",
        )
        return response

    @app.post("/api/auth/logout")
    def logout(request: Request) -> Response:
        _require_auth(request, session_key)
        response = JSONResponse({"ok": True})
        response.delete_cookie(COOKIE_NAME, path="/")
        return response

    @app.post("/api/auth/password")
    async def change_password(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict):
            raise _json_error(400, "Invalid body")
        current = body.get("current_password")
        new = body.get("new_password")
        if not isinstance(current, str) or not verify_password(current, _read_password_hash()):
            raise _json_error(403, "Current password is invalid")
        if not isinstance(new, str):
            raise _json_error(400, "New password is required")
        try:
            encoded = hash_password(new)
        except ValueError as exc:
            raise _json_error(400, str(exc)) from exc
        temp = PASSWORD_HASH_PATH.with_suffix(".tmp")
        temp.write_text(encoded + "\n", encoding="utf-8")
        os.chmod(temp, 0o600)
        os.replace(temp, PASSWORD_HASH_PATH)
        return {"ok": True}

    @app.get("/api/status")
    def status(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        state = runtime.health.snapshot()
        printer_state = _printer_runtime_snapshot(runtime)
        return {
            "version": __version__,
            "uptime_seconds": max(0, int(time.time()) - state["started_at"]),
            "mqtt": {
                "connected": runtime.mqtt_client.connected.is_set(),
                "host": runtime.config.mqtt.host,
                "port": runtime.config.mqtt.port,
                "namespace": runtime.config.mqtt.namespace,
            },
            "weather": state["weather"],
            "news": state["news"],
            "printer": {
                "state": printer_state["state"],
                "configured_devices": printer_state["configured_devices"],
                "enabled_devices": printer_state["enabled_devices"],
                "online_devices": printer_state["online_devices"],
            },
            "admin": {"listen": runtime.config.admin.listen, "port": runtime.config.admin.port},
            "system": _system_metrics(),
        }

    def update_payload() -> dict[str, Any]:
        payload = runtime.update_checker.snapshot()
        payload["installer"] = load_update_install_status()
        return payload

    @app.get("/api/update")
    def update_status(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        return update_payload()

    @app.post("/api/update/check")
    def update_check(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        runtime.update_checker.trigger()
        return update_payload()

    @app.post("/api/update/install", status_code=202)
    def update_install(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        snapshot = runtime.update_checker.snapshot()
        if snapshot.get("state") != "available":
            raise _json_error(409, "No verified update is currently available")
        channel = snapshot.get("channel")
        if channel not in {"stable", "dev"}:
            raise _json_error(409, "This installation channel cannot be updated from Web Admin")
        try:
            queued = queue_update_request(channel)
        except FileExistsError as exc:
            raise _json_error(409, str(exc)) from exc
        except (OSError, RuntimeError, ValueError) as exc:
            LOG.error("Unable to queue privileged update: %s", exc)
            raise _json_error(503, str(exc)) from exc
        payload = update_payload()
        payload["request"] = queued
        return payload

    @app.get("/api/services")
    def services(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        state = runtime.health.snapshot()
        printer_state = _printer_runtime_snapshot(runtime)
        return {
            "services": build_service_catalog(
                state["weather"],
                runtime.config.weather.enabled,
                state["news"],
                runtime.config.news.enabled,
                runtime.config.news.provider,
                printer_state,
                runtime.config.printer.enabled,
            ),
        }

    @app.get("/api/data")
    def data_snapshot(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        state = runtime.health.snapshot()
        return {
            "captured_at": int(time.time()),
            "mqtt": {
                "connected": runtime.mqtt_client.connected.is_set(),
                "namespace": runtime.config.mqtt.namespace,
            },
            "weather": {
                "enabled": runtime.config.weather.enabled,
                "health": state["weather"],
                "messages": _retained_messages(runtime, "weather"),
            },
            "news": {
                "enabled": runtime.config.news.enabled,
                "health": state["news"],
                "messages": _retained_messages(runtime, "news"),
            },
            "printer": {
                "enabled": runtime.config.printer.enabled,
                "health": _printer_runtime_snapshot(runtime),
                "messages": _retained_messages(runtime, "printer"),
            },
        }

    @app.get("/api/printer/config")
    def printer_config(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        p = runtime.config.printer
        return {
            "enabled": p.enabled,
            "poll_interval": p.poll_interval,
            "request_timeout": p.request_timeout,
            "devices": [
                {
                    "id": device.id,
                    "driver": device.driver,
                    "host": device.host,
                    "enabled": device.enabled,
                    "port": device.port,
                    "reconnect_min_delay": device.reconnect_min_delay,
                    "reconnect_max_delay": device.reconnect_max_delay,
                    "access_code_configured": bool(_configured_secret(device.access_code_file)),
                }
                for device in p.devices
            ],
        }

    @app.get("/api/printer/runtime")
    def printer_runtime(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        return _printer_runtime_snapshot(runtime)

    @app.post("/api/printer/test")
    async def printer_test(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict) or not isinstance(body.get("device"), dict):
            raise _json_error(400, "device is required")
        device_body = dict(body["device"])
        device_body["enabled"] = True
        candidate, access_codes, _provided = _candidate_printer(
            runtime,
            {
                "enabled": True,
                "poll_interval": runtime.config.printer.poll_interval,
                "request_timeout": body.get("request_timeout", runtime.config.printer.request_timeout),
                "devices": [device_body],
            },
        )
        device = candidate.devices[0]
        access_code = access_codes.get(device.id)
        if not access_code:
            raise _json_error(400, "Access code is required for the connection test")
        try:
            result = _probe_printer(device, access_code, candidate.request_timeout)
            LOG.info("Printer connection test succeeded: %s", device.id)
            return result
        except PrinterError as exc:
            LOG.warning("Printer connection test failed for %s: %s", device.id, exc)
            raise _json_error(502, str(exc)) from exc

    @app.post("/api/printer/config")
    async def printer_save(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict):
            raise _json_error(400, "Invalid body")
        candidate, _access_codes, provided_codes = _candidate_printer(runtime, body)

        old_config = runtime.config_path.read_text(encoding="utf-8")
        old_secrets = {path: _configured_secret(path) for path in provided_codes}
        try:
            for path, value in provided_codes.items():
                update_secret(path, value)
            update_printer_config(runtime.config_path, candidate)
            runtime.reload_printer()
            LOG.info("Printer configuration applied: %d device(s)", len(candidate.devices))
        except Exception as exc:
            try:
                runtime.config_path.write_text(old_config, encoding="utf-8")
                os.chmod(runtime.config_path, 0o660)
                for path, previous in old_secrets.items():
                    if previous is None:
                        try:
                            path.unlink()
                        except FileNotFoundError:
                            pass
                    else:
                        update_secret(path, previous)
                runtime.reload_printer()
            except Exception:
                pass
            raise _json_error(500, f"Configuration not applied: {type(exc).__name__}") from exc
        return {"ok": True, "runtime": _printer_runtime_snapshot(runtime)}

    @app.get("/api/printer/thumbnail/{printer_id}")
    def printer_thumbnail(request: Request, printer_id: str) -> Response:
        _require_auth(request, session_key)
        if not any(device.id == printer_id for device in runtime.config.printer.devices):
            raise _json_error(404, "Unknown printer")
        collector = runtime.printer_collector
        png = collector.thumbnail_png(printer_id) if collector is not None else None
        if png is None:
            raise _json_error(404, "No thumbnail is currently cached")
        return Response(content=png, media_type="image/png")

    @app.get("/api/logs")
    def logs(request: Request, service: str = "all", limit: int = 200) -> dict[str, Any]:
        _require_auth(request, session_key)
        if service != "all" and service not in LOG_SERVICES:
            raise _json_error(400, "Unknown log service")
        return {
            "service": service,
            "services": ["all", *LOG_SERVICES],
            "entries": recent_logs(service, limit=limit),
        }

    @app.get("/api/weather/config")
    def weather_config(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        w = runtime.config.weather
        return {
            "enabled": w.enabled,
            "provider": w.provider,
            "latitude": w.latitude,
            "longitude": w.longitude,
            "location_name": w.location_name,
            "lang": w.lang,
            "current_interval": w.current_interval,
            "hourly_interval": w.hourly_interval,
            "daily_interval": w.daily_interval,
            "hourly_hours": w.hourly_hours,
            "daily_days": w.daily_days,
            "request_timeout": w.request_timeout,
            "api_key_configured": bool(_configured_secret(w.api_key_file)),
        }

    @app.post("/api/weather/geocode")
    async def weather_geocode(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict) or not isinstance(body.get("query"), str) or not body["query"].strip():
            raise _json_error(400, "Location query is required")
        provided = body.get("api_key")
        key = provided.strip() if isinstance(provided, str) and provided.strip() else _configured_secret(runtime.config.weather.api_key_file)
        if not key:
            raise _json_error(400, "OpenWeather API key is required")
        try:
            results = geocode_locations(body["query"].strip(), key, timeout=runtime.config.weather.request_timeout)
        except WeatherError as exc:
            raise _json_error(502, str(exc)) from exc
        return {"results": results}

    @app.post("/api/weather/test")
    async def weather_test(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict):
            raise _json_error(400, "Invalid body")
        candidate, key = _candidate_weather(runtime, body)
        if not candidate.enabled:
            return {"ok": True, "disabled": True, "temperature_c": None, "hourly_records": 0}
        try:
            result = _test_weather(candidate, key or "")
            LOG.info("Weather provider test succeeded")
            return result
        except WeatherError as exc:
            raise _json_error(502, str(exc)) from exc

    @app.post("/api/weather/config")
    async def weather_save(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict):
            raise _json_error(400, "Invalid body")
        candidate, key = _candidate_weather(runtime, body)
        if candidate.enabled:
            try:
                _test_weather(candidate, key or "")
            except WeatherError as exc:
                raise _json_error(502, str(exc)) from exc

        old_config = runtime.config_path.read_text(encoding="utf-8")
        old_key = _configured_secret(runtime.config.weather.api_key_file)
        key_path = candidate.api_key_file
        try:
            if isinstance(body.get("api_key"), str) and body["api_key"].strip():
                update_secret(key_path, body["api_key"])
            update_weather_config(runtime.config_path, candidate)
            runtime.reload_weather()
            LOG.info("Weather configuration applied")
        except Exception as exc:
            try:
                runtime.config_path.write_text(old_config, encoding="utf-8")
                os.chmod(runtime.config_path, 0o660)
                if old_key is not None:
                    update_secret(key_path, old_key)
                elif key_path.exists():
                    key_path.unlink()
                runtime.reload_weather()
            except Exception:
                pass
            raise _json_error(500, f"Configuration not applied: {type(exc).__name__}") from exc
        return {"ok": True}

    @app.get("/api/news/config")
    def news_config(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        n = runtime.config.news
        return {
            "enabled": n.enabled,
            "provider": n.provider,
            "mode": n.mode,
            "query": n.query,
            "sources": n.sources,
            "country": n.country,
            "category": n.category,
            "search_in": n.search_in,
            "domains": n.domains,
            "exclude_domains": n.exclude_domains,
            "from": n.from_date,
            "to": n.to_date,
            "lang": n.lang,
            "sort_by": n.sort_by,
            "nullable": n.nullable,
            "max_articles": n.max_articles,
            "interval": n.interval,
            "request_timeout": n.request_timeout,
            "api_key_configured": bool(_configured_secret(n.api_key_file)),
            "api_keys_configured": {
                "newsapi": bool(_configured_secret(n.api_key_file if n.provider == "newsapi" else DEFAULT_NEWSAPI_KEY_PATH)),
                "gnews": bool(_configured_secret(n.api_key_file if n.provider == "gnews" else DEFAULT_GNEWS_KEY_PATH)),
            },
            "auth": "X-Api-Key",
            "transport": "HTTPS",
        }

    @app.post("/api/news/test")
    async def news_test(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict):
            raise _json_error(400, "Invalid body")
        candidate, key = _candidate_news(runtime, body)
        if not key:
            raise _json_error(400, f"{_provider_label(candidate.provider)} API key is required for a provider test")
        try:
            result = _test_news(candidate, key)
            LOG.info("News provider test succeeded: %s, %s article(s)", result.get("provider_label"), result.get("article_count"))
            return result
        except NewsError as exc:
            raise _json_error(502, str(exc)) from exc

    @app.post("/api/news/config")
    async def news_save(request: Request) -> dict[str, Any]:
        _require_mutation_guard(request, session_key)
        body = await request.json()
        if not isinstance(body, dict):
            raise _json_error(400, "Invalid body")
        candidate, key = _candidate_news(runtime, body)
        provided_key = isinstance(body.get("api_key"), str) and bool(body["api_key"].strip())
        if candidate.enabled or provided_key:
            try:
                _test_news(candidate, key or "")
            except NewsError as exc:
                raise _json_error(502, str(exc)) from exc

        old_config = runtime.config_path.read_text(encoding="utf-8")
        key_path = candidate.api_key_file
        old_key = _configured_secret(key_path)
        try:
            if isinstance(body.get("api_key"), str) and body["api_key"].strip():
                update_secret(key_path, body["api_key"])
            update_news_config(runtime.config_path, candidate)
            runtime.reload_news()
            LOG.info("News configuration applied: %s", candidate.provider)
        except Exception as exc:
            try:
                runtime.config_path.write_text(old_config, encoding="utf-8")
                os.chmod(runtime.config_path, 0o660)
                if old_key is not None:
                    update_secret(key_path, old_key)
                elif key_path.exists():
                    key_path.unlink()
                runtime.reload_news()
            except Exception:
                pass
            raise _json_error(500, f"Configuration not applied: {type(exc).__name__}") from exc
        return {"ok": True}
