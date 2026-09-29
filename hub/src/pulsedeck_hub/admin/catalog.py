"""Service catalog metadata for the PulseDeck Admin navigation."""

from __future__ import annotations

from typing import Any


def build_service_catalog(
    weather_state: dict[str, Any],
    weather_enabled: bool,
    news_state: dict[str, Any],
    news_enabled: bool,
    news_provider: str = "newsapi",
    printer_state: dict[str, Any] | None = None,
    printer_enabled: bool = False,
) -> list[dict[str, Any]]:
    """Return stable Admin metadata for implemented and planned collectors."""

    return [
        {
            "id": "weather",
            "label": "Weather",
            "available": True,
            "state": weather_state.get("state", "disabled"),
            "enabled": weather_enabled,
            "provider": "OpenWeather One Call 4.0",
            "transport": "HTTPS",
            "auth": "API key",
            "view": "weather",
        },
        {
            "id": "news",
            "label": "News",
            "available": True,
            "state": news_state.get("state", "disabled"),
            "enabled": news_enabled,
            "provider": "GNews" if news_provider == "gnews" else "NewsAPI",
            "transport": "HTTPS",
            "auth": "X-Api-Key",
            "view": "news",
        },
        {
            "id": "pc_gamer",
            "label": "PC gamer",
            "available": False,
            "state": "planned",
            "enabled": False,
            "provider": None,
            "transport": None,
            "auth": None,
            "view": None,
        },
        {
            "id": "printer",
            "label": "Printer",
            "available": True,
            "state": (printer_state or {}).get("state", "disabled"),
            "enabled": printer_enabled,
            "provider": "ELEGOO CC2",
            "transport": "MQTT LAN",
            "auth": "Access code",
            "view": "printer",
        },
        {
            "id": "mini_server",
            "label": "Mini server",
            "available": False,
            "state": "planned",
            "enabled": False,
            "provider": None,
            "transport": None,
            "auth": None,
            "view": None,
        },
    ]
