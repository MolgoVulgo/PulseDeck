"""HTTP routes for the LAN-only PulseDeck administration interface."""

from __future__ import annotations

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
    NewsConfig,
    WeatherConfig,
    news_config_from_mapping,
    weather_config_from_mapping,
)
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
from .storage import update_news_config, update_secret, update_weather_config
from .ui import ADMIN_HTML


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
            "admin": {"listen": runtime.config.admin.listen, "port": runtime.config.admin.port},
            "system": _system_metrics(),
        }

    @app.get("/api/services")
    def services(request: Request) -> dict[str, Any]:
        _require_auth(request, session_key)
        state = runtime.health.snapshot()
        return {
            "services": build_service_catalog(
                state["weather"],
                runtime.config.weather.enabled,
                state["news"],
                runtime.config.news.enabled,
                runtime.config.news.provider,
            ),
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
            return _test_weather(candidate, key or "")
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
            return _test_news(candidate, key)
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
