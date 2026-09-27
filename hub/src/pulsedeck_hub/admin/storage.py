"""Atomic persistence helpers for settings changed by the admin UI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import tempfile

from ..config import WeatherConfig


_WEATHER_SECTION = re.compile(r"(?ms)^\[collectors\.weather\]\n.*?(?=^\[|\Z)")


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


def update_weather_config(path: Path, config: WeatherConfig) -> None:
    text = path.read_text(encoding="utf-8")
    section = render_weather_section(config)
    if _WEATHER_SECTION.search(text):
        text = _WEATHER_SECTION.sub(section + "\n", text, count=1)
    else:
        text = text.rstrip() + "\n\n" + section
    _atomic_write(path, text, mode=0o660)


def update_secret(path: Path, value: str) -> None:
    if not value.strip():
        raise ValueError("secret must not be empty")
    _atomic_write(path, value.strip() + "\n", mode=0o660)
