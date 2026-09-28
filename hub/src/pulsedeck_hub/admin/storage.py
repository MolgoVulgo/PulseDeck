"""Atomic persistence helpers for settings changed by the admin UI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import tempfile

from ..config import NewsConfig, WeatherConfig


_WEATHER_SECTION = re.compile(r"(?ms)^\[collectors\.weather\]\n.*?(?=^\[|\Z)")
_NEWS_SECTION = re.compile(r"(?ms)^\[collectors\.news\]\n.*?(?=^\[|\Z)")


def _atomic_write(path: Path, content: str, *, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def _replace_section(path: Path, pattern: re.Pattern[str], section: str) -> None:
    text = path.read_text(encoding="utf-8")
    if pattern.search(text):
        text = pattern.sub(section + "\n", text, count=1)
    else:
        text = text.rstrip() + "\n\n" + section
    _atomic_write(path, text, mode=0o660)


def render_weather_section(config: WeatherConfig) -> str:
    lines = [
        "[collectors.weather]",
        f"enabled = {'true' if config.enabled else 'false'}",
        'provider = "openweather-onecall-4"',
    ]
    if config.latitude is not None:
        lines.append(f"latitude = {config.latitude!r}")
    if config.longitude is not None:
        lines.append(f"longitude = {config.longitude!r}")
    lines.extend(
        [
            f"location_name = {json.dumps(config.location_name, ensure_ascii=False)}",
            f"api_key_file = {json.dumps(str(config.api_key_file))}",
            f"lang = {json.dumps(config.lang)}",
            f"current_interval = {config.current_interval}",
            f"hourly_interval = {config.hourly_interval}",
            f"daily_interval = {config.daily_interval}",
            f"hourly_hours = {config.hourly_hours}",
            f"daily_days = {config.daily_days}",
            f"request_timeout = {config.request_timeout}",
        ]
    )
    return "\n".join(lines) + "\n"


def render_news_section(config: NewsConfig) -> str:
    return "\n".join(
        [
            "[collectors.news]",
            f"enabled = {'true' if config.enabled else 'false'}",
            'provider = "newsapi"',
            f"mode = {json.dumps(config.mode)}",
            f"category = {json.dumps(config.category)}",
            f"query = {json.dumps(config.query, ensure_ascii=False)}",
            f"lang = {json.dumps(config.lang)}",
            f"country = {json.dumps(config.country)}",
            f"max_articles = {config.max_articles}",
            f"interval = {config.interval}",
            f"request_timeout = {config.request_timeout}",
            f"api_key_file = {json.dumps(str(config.api_key_file))}",
        ]
    ) + "\n"


def update_weather_config(path: Path, config: WeatherConfig) -> None:
    _replace_section(path, _WEATHER_SECTION, render_weather_section(config))


def update_news_config(path: Path, config: NewsConfig) -> None:
    _replace_section(path, _NEWS_SECTION, render_news_section(config))


def update_secret(path: Path, value: str) -> None:
    if not value.strip():
        raise ValueError("secret must not be empty")
    _atomic_write(path, value.strip() + "\n", mode=0o660)
