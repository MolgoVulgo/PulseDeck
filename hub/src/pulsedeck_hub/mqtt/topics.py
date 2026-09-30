"""MQTT topic helpers for the PulseDeck V1 namespace."""

from __future__ import annotations


def topic(namespace: str, suffix: str) -> str:
    return f"{namespace.strip('/')}/{suffix.lstrip('/')}"


def system_availability(namespace: str = "pulsedeck/v1") -> str:
    return topic(namespace, "system/availability")


TOPIC_SUFFIXES = {
    "weather_availability": "weather/availability",
    "weather_current": "weather/current",
    "weather_hourly": "weather/hourly",
    "weather_daily": "weather/daily",
    "news_availability": "news/availability",
    "news_latest": "news/latest",
    "printer_availability": "printer/availability",
    "printer_status": "printer/status",
    "printer_job": "printer/job",
    "printer_thumbnail": "printer/thumbnail",
}


def printer_suffix(printer_id: str, leaf: str) -> str:
    """Return one multi-printer application suffix below ``printer/<id>``."""
    return f"printer/{printer_id}/{leaf.lstrip('/')}"


def machine_suffix(machine_id: str, leaf: str) -> str:
    """Return a per-machine application suffix below ``machine/<id>``."""
    return f"machine/{machine_id}/{leaf.lstrip('/')}"
