"""Service catalog metadata for the PulseDeck Admin navigation."""

from __future__ import annotations

from typing import Any


def build_service_catalog(weather_state: dict[str, Any], weather_enabled: bool) -> list[dict[str, Any]]:
    """Return stable Admin metadata for implemented and planned collectors.

    The catalog deliberately contains only contracts already confirmed for a service.
    Unknown PC/Printer/Mini-server provider details remain unspecified until their
    implementation patches define them.
    """

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
            "available": False,
            "state": "planned",
            "enabled": False,
            "provider": "GNews",
            "transport": "HTTPS",
            "auth": "X-Api-Key",
            "view": None,
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
            "available": False,
            "state": "planned",
            "enabled": False,
            "provider": None,
            "transport": None,
            "auth": None,
            "view": None,
        },
        {
            "id": "mini_server",
            "label": "Mini serveur",
            "available": False,
            "state": "planned",
            "enabled": False,
            "provider": None,
            "transport": None,
            "auth": None,
            "view": None,
        },
    ]
