"""Logging setup for systemd/journald execution and the Admin log view."""

from __future__ import annotations

from collections import deque
import logging
import threading
from typing import Any


LOG_SERVICES = ("hub", "mqtt", "weather", "news", "admin")
_MAX_LOG_ENTRIES = 500
_LOG_ENTRIES: deque[dict[str, Any]] = deque(maxlen=_MAX_LOG_ENTRIES)
_LOG_LOCK = threading.RLock()


def classify_log_service(logger_name: str) -> str:
    """Map a Python logger to one stable Admin service filter."""

    name = logger_name.lower()
    if ".collectors.weather" in name:
        return "weather"
    if ".collectors.news" in name:
        return "news"
    if ".mqtt." in name or name.endswith(".mqtt"):
        return "mqtt"
    if ".admin." in name or name.endswith(".admin") or name.startswith("uvicorn"):
        return "admin"
    return "hub"


class _AdminBufferHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        try:
            message = record.getMessage()
        except Exception:
            message = "<unformattable log message>"
        entry = {
            "ts": record.created,
            "level": record.levelname,
            "service": classify_log_service(record.name),
            "logger": record.name,
            "message": message[:4000],
        }
        with _LOG_LOCK:
            _LOG_ENTRIES.append(entry)


_ADMIN_HANDLER = _AdminBufferHandler(level=logging.INFO)


def recent_logs(service: str = "all", *, limit: int = 200) -> list[dict[str, Any]]:
    """Return recent in-process logs, newest entries last."""

    if service != "all" and service not in LOG_SERVICES:
        raise ValueError("unknown log service")
    limit = max(1, min(int(limit), _MAX_LOG_ENTRIES))
    with _LOG_LOCK:
        entries = list(_LOG_ENTRIES)
    if service != "all":
        entries = [entry for entry in entries if entry["service"] == service]
    return entries[-limit:]


def clear_log_buffer() -> None:
    """Clear the in-memory buffer (used by tests)."""

    with _LOG_LOCK:
        _LOG_ENTRIES.clear()


def configure_logging(level: int = logging.INFO) -> None:
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    root = logging.getLogger()
    if _ADMIN_HANDLER not in root.handlers:
        root.addHandler(_ADMIN_HANDLER)
