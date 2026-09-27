"""Thread-safe runtime health state exposed to the local admin UI."""

from __future__ import annotations

import threading
import time
from typing import Any


class HealthState:
    def __init__(self) -> None:
        self.started_at = int(time.time())
        self._lock = threading.Lock()
        self._weather: dict[str, Any] = {
            "enabled": False,
            "state": "disabled",
            "last_current": None,
            "last_hourly": None,
            "last_daily": None,
            "hourly_records": None,
            "daily_records": None,
            "last_error": None,
            "last_error_at": None,
            "last_error_kind": None,
        }

    def configure_weather(self, enabled: bool) -> None:
        with self._lock:
            self._weather["enabled"] = enabled
            self._weather["state"] = "starting" if enabled else "disabled"
            if not enabled:
                self._weather["last_error"] = None
                self._weather["last_error_at"] = None
                self._weather["last_error_kind"] = None

    def weather_started(self) -> None:
        with self._lock:
            self._weather["enabled"] = True
            self._weather["state"] = "starting"

    def weather_current_success(self) -> None:
        now = int(time.time())
        with self._lock:
            self._weather["state"] = "online"
            self._weather["last_current"] = now
            if self._weather.get("last_error_kind") == "current":
                self._clear_error_locked()

    def weather_hourly_success(self, records: int) -> None:
        now = int(time.time())
        with self._lock:
            self._weather["last_hourly"] = now
            self._weather["hourly_records"] = records
            if self._weather.get("last_error_kind") == "hourly":
                self._clear_error_locked()

    def weather_daily_success(self, records: int) -> None:
        now = int(time.time())
        with self._lock:
            self._weather["last_daily"] = now
            self._weather["daily_records"] = records
            if self._weather.get("last_error_kind") == "daily":
                self._clear_error_locked()

    def weather_error(self, kind: str, message: str) -> None:
        with self._lock:
            if kind == "current":
                self._weather["state"] = "offline"
            self._weather["last_error"] = message
            self._weather["last_error_at"] = int(time.time())
            self._weather["last_error_kind"] = kind

    def weather_stopped(self) -> None:
        with self._lock:
            if self._weather.get("enabled"):
                self._weather["state"] = "stopped"

    def _clear_error_locked(self) -> None:
        self._weather["last_error"] = None
        self._weather["last_error_at"] = None
        self._weather["last_error_kind"] = None

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "started_at": self.started_at,
                "weather": dict(self._weather),
            }
